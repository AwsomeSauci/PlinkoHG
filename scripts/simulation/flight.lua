local Random = require "scripts.domain.random"

local Flight = {}

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function pegIndex(row, column)
    return row * (row - 1) / 2 + column
end

local function addSegment(segments, startX, startY, endX, endY, velocityY, gravity, contact)
    local distanceY = startY - endY
    local duration = (velocityY + math.sqrt(velocityY * velocityY + 2 * gravity * distanceY)) / gravity
    local previous = segments[#segments]
    local startTime = previous and previous.endTime or 0
    segments[#segments + 1] = {
        startX = startX,
        startY = startY,
        endX = endX,
        endY = endY,
        velocityX = (endX - startX) / duration,
        velocityY = velocityY,
        startTime = startTime,
        endTime = startTime + duration,
        pegIndex = contact,
    }
end

local function bounceVelocity(board, peg, endX, endY, random)
    local radius = board.BallRadius + board.PegRadius
    local horizontal = math.abs(endX - peg.X)
    local vertical = peg.Y + radius - endY

    -- Let u be normalized flight time and A = vertical impulse * duration.
    -- y(u) = A*u*(1-u) - vertical*u. Choose A so the ball stays at or
    -- above its starting height until horizontal displacement > both radii.
    -- It therefore cannot re-enter the peg it has just left. The 0.35 margin
    -- absorbs floating-point error and keeps a visible gap on dense boards.
    local clearance = radius + 0.35
    local requiredA = clearance * vertical / (horizontal - clearance)
    local minimumHeight = math.max(4, requiredA * requiredA / (4 * (vertical + requiredA)) + 0.15)
    local maximumHeight = minimumHeight + 2.5

    if peg.Row > 1 then
        -- The entire arc remains below the preceding row's collision circles,
        -- even when this branch turns back toward the preceding contact.
        maximumHeight = math.min(maximumHeight, board.RowSpacing - 2 * radius - 0.75)
    end
    assert(minimumHeight <= maximumHeight, "Board geometry cannot fit a collision-free bounce")
    local height = minimumHeight + Random.Next(random) * (maximumHeight - minimumHeight)
    return math.sqrt(2 * board.Gravity * height)
end

-- The domain commits the weighted outcome before a flight is constructed.
-- These are art-directed collision impulses with ordinary ballistic motion
-- between contacts, not an unmodified Box2D/Galton simulation: a passive Galton
-- board cannot guarantee arbitrary configured basket probabilities. No force,
-- position correction, outcome selection, or randomness is applied per frame.
function Flight.New(board, drop)
    assert(type(board) == "table" and type(board.Pegs) == "table"
        and type(board.Baskets) == "table" and #board.Pegs > 0,
        "Flight.New requires a Board.New board")
    assert(type(drop) == "table" and drop.Id ~= nil, "Flight.New requires a drop Id")
    assert(finite(drop.BasketIndex) and drop.BasketIndex == math.floor(drop.BasketIndex)
        and drop.BasketIndex >= 1 and drop.BasketIndex <= #board.Baskets,
        "Flight.New requires a valid basket index")
    assert(finite(drop.Seed) and drop.Seed == math.floor(drop.Seed),
        "Flight.New requires an integer trajectory seed")

    local random = Random.New(drop.Seed)
    local radius = board.BallRadius + board.PegRadius
    local first = board.Pegs[1]
    local segments = {}
    addSegment(segments, board.Spawn.X, board.Spawn.Y, first.X, first.Y + radius,
        0, board.Gravity, 1)

    local column = 1
    local rights = drop.BasketIndex - 1
    for row = 1, board.Rows do
        local remaining = board.Rows - row + 1
        -- Sampling without replacement gives a bridge with exactly the number
        -- of right steps required by the committed basket. Edge paths remain
        -- reachable, and interior paths vary reproducibly with the drop seed.
        local right = Random.Next(random) < rights / remaining
        local nextColumn = column + (right and 1 or 0)
        if right then
            rights = rights - 1
        end

        local peg = board.Pegs[pegIndex(row, column)]
        local destination, contact, endY
        if row < board.Rows then
            contact = pegIndex(row + 1, nextColumn)
            destination = board.Pegs[contact]
            endY = destination.Y + radius
        else
            destination = board.Baskets[nextColumn]
            endY = destination.Y
        end
        local velocityY = bounceVelocity(board, peg, destination.X, endY, random)
        addSegment(segments, peg.X, peg.Y + radius, destination.X, endY,
            velocityY, board.Gravity, contact)
        column = nextColumn
    end

    return {
        Id = drop.Id,
        BasketIndex = drop.BasketIndex,
        X = board.Spawn.X,
        Y = board.Spawn.Y,
        Done = false,
        segments = segments,
        segmentIndex = 1,
        elapsed = 0,
        duration = segments[#segments].endTime,
        gravity = board.Gravity,
    }
end

-- Returns chronological board.Pegs indices, once per contact. A large delta
-- crosses any number of segments without dropping events or consuming RNG.
-- Ordinary frames allocate nothing. Done becomes true only at basket landing.
function Flight.Update(flight, dt)
    assert(finite(dt) and dt >= 0, "Flight.Update requires a finite non-negative delta")
    if flight.Done then
        return nil
    end

    flight.elapsed = math.min(flight.elapsed + dt, flight.duration)
    local contacts
    local segment = flight.segments[flight.segmentIndex]
    while segment and flight.elapsed >= segment.endTime do
        if segment.pegIndex then
            contacts = contacts or {}
            contacts[#contacts + 1] = segment.pegIndex
        end
        -- Exact endpoint assignment removes only round-off in the analytic
        -- formula; adjacent segments share this same point by construction.
        flight.X, flight.Y = segment.endX, segment.endY
        flight.segmentIndex = flight.segmentIndex + 1
        segment = flight.segments[flight.segmentIndex]
    end

    if segment then
        local elapsed = flight.elapsed - segment.startTime
        flight.X = segment.startX + segment.velocityX * elapsed
        flight.Y = segment.startY + segment.velocityY * elapsed - 0.5 * flight.gravity * elapsed * elapsed
    else
        flight.Done = true
    end
    return contacts
end

return Flight
