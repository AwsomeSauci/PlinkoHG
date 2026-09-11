local Session = require "scripts.domain.session"
local Game = {}

local function emit(game, kind, drop, detail)
    game.events[#game.events + 1] = {Kind = kind, Drop = drop, Detail = detail}
end

local function changed(game, urgent)
    game.generation = game.generation + 1
    if urgent then game.urgentGeneration = game.generation end
end

-- Local use cases and checkpoint generations, without a storage dependency.
-- Capture/Confirm never assume that a repository responds synchronously.
function Game.New(config, now, snapshot, registry)
    local session = Session.New(config, now, snapshot, registry)
    for index, drop in ipairs(session.Pending) do
        if drop.BasketIndex == 0 then Session.Land(session, drop.Id, now) end
    end
    return {session = session, events = {}, started = {}, waiting = {}, reported = {},
        elapsed = 0, retryElapsed = 0, generation = 0, confirmed = -1, urgentGeneration = 0}
end

local function settle(game, id, now)
    local result, err = Session.Complete(game.session, id, now)
    if result then
        game.started[id], game.waiting[id], game.reported[id] = nil, nil, nil
        changed(game)
        emit(game, "Awarded", result)
    elseif err then
        game.waiting[id] = true
        if game.reported[id] ~= err then emit(game, "RewardFailed", nil, err); game.reported[id] = err end
    end
end

function Game.Checkpoint(game, now)
    if Session.Advance(game.session, now) > 0 then changed(game) end
    return {Generation = game.generation, Snapshot = Session.Snapshot(game.session)}
end

function Game.Confirm(game, checkpoint)
    game.confirmed, game.elapsed = math.max(game.confirmed, checkpoint.Generation), 0
    -- Release only outcomes contained in the acknowledged snapshot. Live state
    -- may include newer landings/payouts, which still need another save.
    for index, drop in ipairs(checkpoint.Snapshot.Pending) do
        if game.session.pendingIndices[drop.Id] and not game.started[drop.Id] then
            game.started[drop.Id] = true
            if drop.Phase == "Landed" then game.waiting[drop.Id] = true
            else
                emit(game, "Started", {Id = drop.Id, BasketId = drop.BasketId,
                    BasketIndex = drop.BasketIndex, Seed = drop.Seed})
            end
        end
    end
end

function Game.NeedsCheckpoint(game)
    -- Keep accepted commands durable before playback, but coalesce landings
    -- from adjacent frames. The last payout and lifecycle requests never wait.
    return game.urgentGeneration > game.confirmed or game.elapsed >= 5
        or (game.generation > game.confirmed and (game.elapsed >= 0.25 or #game.session.Pending == 0))
end

function Game.GetGeneration(game) return game.generation end
function Game.GetConfirmed(game) return game.confirmed end

function Game.RequestCheckpoint(game, now)
    Session.Advance(game.session, now)
    changed(game, true) -- includes clock/deadline metadata even without an economy change
end

function Game.Drop(game, count, now)
    local drops, err = Session.Drop(game.session, count, now)
    if not drops then return nil, err end
    changed(game, true)
    return true
end

function Game.Grant(game, now)
    local amount = Session.Grant(game.session, now)
    changed(game, true)
    return amount
end

function Game.Land(game, id, now)
    if game.started[id] and not game.waiting[id] then
        if Session.Land(game.session, id, now) then changed(game) end
        settle(game, id, now)
    end
end

function Game.Update(game, now, dt)
    assert(type(dt) == "number" and dt >= 0 and dt < math.huge, "Game.Update requires finite delta")
    if Session.Advance(game.session, now) > 0 then changed(game) end
    game.elapsed, game.retryElapsed = game.elapsed + dt, game.retryElapsed + dt
    if game.retryElapsed >= 1 then
        game.retryElapsed = 0
        for id in pairs(game.waiting) do settle(game, id, now) end
    end
end

function Game.Resume(game, now)
    local amount = Session.Advance(game.session, now)
    if amount > 0 then changed(game) end
    return amount
end

function Game.View(game, includeDetails) return Session.View(game.session, includeDetails) end

function Game.DrainEvents(game)
    local events = game.events
    game.events = {}
    return events
end

return Game
