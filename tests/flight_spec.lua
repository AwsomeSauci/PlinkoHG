-- Standalone Lua 5.1 / LuaJIT specification. No engine or third-party runner.
-- Run from the project root only when explicitly authorised:
--     lua tests/flight_spec.lua
local Board = require "scripts.simulation.board"
local Flight = require "scripts.simulation.flight"

local cases = {}

local function test(name, callback)
    cases[#cases + 1] = { Name = name, Run = callback }
end

local function equal(actual, expected, message)
    assert(actual == expected, (message or "Values differ")
        .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function near(actual, expected, tolerance)
    assert(math.abs(actual - expected) <= tolerance,
        "Expected " .. expected .. " +/- " .. tolerance .. ", got " .. actual)
end

local function append(destination, source)
    for index, value in ipairs(source or {}) do
        destination[#destination + 1] = value
    end
end

local function newFlight(board, basketIndex, seed)
    return Flight.New(board, { Id = 123, BasketIndex = basketIndex, Seed = seed or 104729 })
end

test("every supported board fits logical bounds and has one fewer rows than baskets", function()
    for count = 2, 16 do
        local board = Board.New(count)
        equal(board.Rows, count - 1)
        equal(#board.Pegs, count * (count - 1) / 2)
        equal(#board.Baskets, count)
        equal(board.Pegs[1].X, 360)
        equal(board.Pegs[1].Y, 790)
        if count > 2 then
            near(board.Pegs[#board.Pegs].Y, 365, 1e-9)
        end
        for index, peg in ipairs(board.Pegs) do
            assert(peg.X - board.PegRadius >= 60 and peg.X + board.PegRadius <= 660)
        end
        for index, basket in ipairs(board.Baskets) do
            assert(basket.X - basket.Width / 2 >= 60 and basket.X + basket.Width / 2 <= 660)
            equal(basket.Y, 292)
        end
    end
end)

test("invalid board counts and drop inputs fail at the boundary", function()
    for index, count in ipairs({ 0, 1, 17, 2.5, "10", math.huge, 0 / 0 }) do
        equal(pcall(Board.New, count), false)
    end
    local board = Board.New(10)
    for index, basket in ipairs({ 0, 11, 1.5, "1", math.huge, 0 / 0 }) do
        equal(pcall(newFlight, board, basket), false)
    end
    equal(pcall(Flight.New, board, { Id = 1, BasketIndex = 1 }), false)
    equal(pcall(Flight.New, board, { Id = 1, BasketIndex = 1, Seed = math.huge }), false)
    equal(pcall(Flight.New, board, { Id = 1, BasketIndex = 1, Seed = 1.5 }), false)
    local flight = newFlight(board, 1)
    for index, dt in ipairs({ -1, "1", math.huge, 0 / 0 }) do
        equal(pcall(Flight.Update, flight, dt), false)
    end
    equal(flight.X, board.Spawn.X)
    equal(flight.Y, board.Spawn.Y)
end)

test("every outcome is reachable and a large delta preserves every peg contact exactly once", function()
    for count = 2, 16 do
        local board = Board.New(count)
        for target = 1, count do
            for index, seed in ipairs({ 1, 17, 2147483646 }) do
                local flight = newFlight(board, target, seed)
                local contacts = assert(Flight.Update(flight, 100))
                equal(flight.Id, 123)
                equal(flight.BasketIndex, target)
                equal(flight.Done, true)
                equal(flight.X, board.Baskets[target].X)
                equal(flight.Y, board.Baskets[target].Y)
                equal(#contacts, board.Rows)
                local previousColumn = 1
                for row, contact in ipairs(contacts) do
                    local peg = board.Pegs[contact]
                    equal(peg.Row, row)
                    assert(peg.Column == previousColumn or peg.Column == previousColumn + 1)
                    previousColumn = peg.Column
                end
                assert(target == previousColumn or target == previousColumn + 1)
                equal(Flight.Update(flight, 100), nil)
                equal(Flight.Update(flight, 0), nil)
            end
        end
    end
end)

test("first-contact boundary emits once without marking a flight complete", function()
    local board = Board.New(10)
    local flight = newFlight(board, 5)
    local contactY = board.Pegs[1].Y + board.BallRadius + board.PegRadius
    local contactTime = math.sqrt(2 * board.Gravity * (board.Spawn.Y - contactY)) / board.Gravity
    equal(Flight.Update(flight, 0), nil)
    local contacts = assert(Flight.Update(flight, contactTime))
    equal(#contacts, 1)
    equal(contacts[1], 1)
    equal(flight.Done, false)
    equal(flight.X, board.Pegs[1].X)
    equal(flight.Y, contactY)
    equal(Flight.Update(flight, 0), nil)
end)

test("initial free fall follows constant gravity", function()
    local board = Board.New(10)
    local flight = newFlight(board, 5)
    local interval = 0.02
    local y0 = flight.Y
    equal(Flight.Update(flight, interval), nil)
    local y1 = flight.Y
    equal(Flight.Update(flight, interval), nil)
    near(flight.Y - 2 * y1 + y0, -board.Gravity * interval * interval, 1e-9)
    equal(flight.X, board.Spawn.X)
    equal(flight.Done, false)
end)

test("trajectory and contact order do not depend on frame partitioning", function()
    local board = Board.New(16)
    for target = 1, 16 do
        local regular = newFlight(board, target, 99991)
        local irregular = newFlight(board, target, 99991)
        local regularContacts, irregularContacts = {}, {}
        -- Binary fractions make the equal total elapsed time exact, avoiding
        -- an unrelated floating-point difference in the test's own clock.
        for interval = 1, 16 do
            for frame = 1, 8 do
                append(regularContacts, Flight.Update(regular, 1 / 64))
            end
            append(irregularContacts, Flight.Update(irregular, 1 / 8))
            near(regular.X, irregular.X, 1e-9)
            near(regular.Y, irregular.Y, 1e-9)
            equal(regular.Done, irregular.Done)
        end
        append(regularContacts, Flight.Update(regular, 100))
        append(irregularContacts, Flight.Update(irregular, 100))
        equal(#regularContacts, #irregularContacts)
        for index, contact in ipairs(regularContacts) do
            equal(contact, irregularContacts[index])
        end
    end
end)

test("sampled trajectories clear all pegs and finish continuously inside the selected basket", function()
    for count = 2, 16 do
        local board = Board.New(count)
        local radius = board.BallRadius + board.PegRadius
        for target = 1, count do
            local flight = newFlight(board, target, 17)
            local frames = 0
            while not flight.Done do
                local previousX, previousY = flight.X, flight.Y
                Flight.Update(flight, 1 / 240)
                frames = frames + 1
                assert(frames < 4800, "Flight failed to finish within 20 seconds")
                assert(flight.X >= 60 and flight.X <= 660)
                assert(flight.Y >= board.Baskets[target].Y)
                -- At this timestep even the long two-basket final fall is
                -- below 6px/frame; this catches visible terminal snapping.
                local moveX, moveY = flight.X - previousX, flight.Y - previousY
                assert(moveX * moveX + moveY * moveY < 36, "Discontinuous flight")
                for index, peg in ipairs(board.Pegs) do
                    local dx, dy = flight.X - peg.X, flight.Y - peg.Y
                    assert(dx * dx + dy * dy >= radius * radius - 1e-7,
                        "Ball penetrates a peg on board " .. count .. ", target " .. target)
                end
            end
            equal(flight.X, board.Baskets[target].X)
            equal(flight.Y, board.Baskets[target].Y)
        end
    end
end)

local failures = 0
for index, case in ipairs(cases) do
    local ok, failure = pcall(case.Run)
    if ok then
        io.write("PASS ", case.Name, "\n")
    else
        failures = failures + 1
        io.write("FAIL ", case.Name, ": ", tostring(failure), "\n")
    end
end
io.write(#cases - failures, "/", #cases, " specifications passed\n")
if failures > 0 then
    error(tostring(failures) .. " flight specifications failed")
end
