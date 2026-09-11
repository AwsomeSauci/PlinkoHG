local Random = require "scripts.domain.random"
local Registry = require "scripts.domain.rewards.registry"
local Data = require "scripts.domain.rewards.data"

local Session = {SnapshotVersion = 3}
local maxInteger = 9007199254740991
local maxTimestamp = 1000000000000

local function isNumber(value, minimum, maximum)
    return type(value) == "number" and value == value
        and value >= minimum and value <= maximum
end

local function isInteger(value, minimum, maximum)
    return isNumber(value, minimum, maximum) and value == math.floor(value)
end

local function validId(value)
    return type(value) == "string" and #value >= 1 and #value <= 64
        and value:match("^[%w%-_]+$") ~= nil
end

local function copyDrop(drop, basketIndex)
    return {
        Id = drop.Id,
        BasketId = drop.BasketId,
        BasketIndex = basketIndex or drop.BasketIndex,
        Rewards = Data.Copy(drop.Rewards),
        Seed = drop.Seed,
        Phase = drop.Phase,
    }
end

local function basketIndices(config)
    local indices = {}
    for index, basket in ipairs(config.Baskets) do
        indices[basket.Id] = index
    end
    return indices
end

-- Reject inconsistent snapshots as a whole. Sanitizing individual payouts or
-- pending entries could silently duplicate/refund a paid drop.
function Session.ValidateSnapshot(config, raw, registry)
    if type(raw) ~= "table" or raw.Version ~= Session.SnapshotVersion then
        return nil, "Unsupported save version"
    end
    local ranges = {
        TotalHits = { 0, maxInteger - 1 },
        SettledCount = { 0, maxInteger - 1 },
        ArchivedHits = { 0, maxInteger - 1 },
        NextDropId = { 1, maxInteger },
        RandomState = { 1, 2147483646 },
        RefillSeconds = { 1, 86400 },
    }
    for field, range in pairs(ranges) do
        if not isInteger(raw[field], range[1], range[2]) then
            return nil, "Invalid save field: " .. field
        end
    end
    if not isNumber(raw.ClockAt, 0, maxTimestamp) then
        return nil, "Invalid saved clock"
    end
    if raw.NextRefillAt ~= nil and (not isNumber(raw.NextRefillAt, raw.ClockAt, maxTimestamp)
        or raw.NextRefillAt - raw.ClockAt > raw.RefillSeconds + 0.001) then
        return nil, "Invalid saved refill deadline"
    end
    if type(raw.HitsById) ~= "table" or type(raw.Pending) ~= "table" then
        return nil, "Invalid saved statistics or pending drops"
    end
    local rewardState, rewardError, incompatible = Registry.ValidateState(registry, raw.RewardState, config)
    if not rewardState then return nil, rewardError, incompatible end

    local indices = basketIndices(config)
    local snapshot = {
        Version = Session.SnapshotVersion,
        RewardState = rewardState,
        TotalHits = raw.TotalHits,
        SettledCount = raw.SettledCount,
        ArchivedHits = raw.ArchivedHits,
        NextDropId = raw.NextDropId,
        RandomState = raw.RandomState,
        ClockAt = raw.ClockAt,
        RefillSeconds = config.RefillSeconds,
        HitsById = {},
        Pending = {},
    }
    local totalHits = raw.ArchivedHits
    local idCount = 0
    for id, count in pairs(raw.HitsById) do
        idCount = idCount + 1
        if idCount > 16 or not validId(id) or not isInteger(count, 0, raw.TotalHits)
            or totalHits > maxInteger - count then
            return nil, "Invalid saved basket statistics"
        end
        totalHits = totalHits + count
        if indices[id] then
            snapshot.HitsById[id] = count
        else
            -- Removed IDs retain their historical contribution to the total,
            -- without attributing it to an unrelated replacement basket.
            snapshot.ArchivedHits = snapshot.ArchivedHits + count
        end
    end
    if totalHits ~= raw.TotalHits then
        return nil, "Saved hit totals do not agree"
    end

    local count = #raw.Pending
    if count > raw.NextDropId - 1 or raw.SettledCount > raw.TotalHits then
        return nil, "Saved drop ledger exceeds its ID range"
    end
    for key in pairs(raw.Pending) do
        if not isInteger(key, 1, count) then
            return nil, "Saved pending drops must be a dense array"
        end
    end
    local ids, landedById, landedCount, landedArchived = {}, {}, 0, 0
    for index = 1, count do
        local drop = raw.Pending[index]
        if type(drop) ~= "table" or not isInteger(drop.Id, 1, raw.NextDropId - 1)
            or ids[drop.Id] or not validId(drop.BasketId)
            or not isInteger(drop.Seed, 1, 2147483646)
            or (drop.Phase ~= "InFlight" and drop.Phase ~= "Landed") then
            return nil, "Invalid or duplicate saved drop"
        end
        ids[drop.Id] = true
        local rewards, errorMessage, unknown = Registry.Normalize(registry, drop.Rewards, config, true)
        if not rewards then return nil, errorMessage, unknown end
        -- The original payout survives balance changes. A removed basket uses
        -- index 0 so the caller can settle it without an impossible animation.
        snapshot.Pending[index] = copyDrop(drop, indices[drop.BasketId] or 0)
        snapshot.Pending[index].Rewards = rewards
        if drop.Phase == "Landed" then
            landedCount = landedCount + 1
            if indices[drop.BasketId] then
                landedById[drop.BasketId] = (landedById[drop.BasketId] or 0) + 1
            else
                landedArchived = landedArchived + 1
            end
        end
    end
    if raw.SettledCount ~= raw.NextDropId - 1 - count
        or landedCount ~= raw.TotalHits - raw.SettledCount then
        return nil, "Saved drop ledger does not agree"
    end
    for id, landed in pairs(landedById) do
        if landed > (snapshot.HitsById[id] or 0) then return nil, "Pending landings exceed basket hits" end
    end
    if landedArchived > snapshot.ArchivedHits then return nil, "Pending landings exceed archived hits" end
    if snapshot.RewardState.balls.Data.Balance < config.RefillCap then
        local remaining = raw.NextRefillAt and (raw.NextRefillAt - raw.ClockAt)
            or config.RefillSeconds
        -- On a refill-rate change, keep the remaining delay, capped by the new
        -- interval. Offline elapsed time is applied by Advance after restore.
        snapshot.NextRefillAt = raw.ClockAt + math.min(remaining, config.RefillSeconds)
    end
    return snapshot
end

function Session.New(config, now, saved, registry)
    assert(type(registry) == "table", "Session requires an explicit reward registry")
    assert(isNumber(now, 0, maxTimestamp), "Session.New requires a valid timestamp")
    local snapshot, restoreError
    if saved ~= nil then
        snapshot, restoreError = Session.ValidateSnapshot(config, saved, registry)
        assert(snapshot, "Cannot restore session: " .. tostring(restoreError))
    end
    local session = snapshot or {
        Version = Session.SnapshotVersion,
        RewardState = Registry.NewState(registry, config),
        TotalHits = 0,
        SettledCount = 0,
        ArchivedHits = 0,
        NextDropId = 1,
        RandomState = Random.New(now * 1000 + 104729).State,
        ClockAt = now,
        RefillSeconds = config.RefillSeconds,
        HitsById = {},
        Pending = {},
    }
    session.Config = config
    session.rewardRegistry = registry
    session.RestoreError = restoreError
    session.Random = { State = session.RandomState }
    session.BasketIndices = basketIndices(config)
    session.pendingIndices, session.rewardFailures, session.pendingRewardCount = {}, {}, 0
    for index, drop in ipairs(session.Pending) do
        session.pendingIndices[drop.Id] = index
        if drop.Phase == "Landed" then session.pendingRewardCount = session.pendingRewardCount + 1 end
    end
    Session.Advance(session, now)
    return session
end

function Session.Advance(session, now)
    if not isNumber(now, 0, maxTimestamp) then
        return 0
    end
    local config = session.Config
    local inventory = session.RewardState.balls.Data
    if now < session.ClockAt and session.NextRefillAt then
        -- Local time is not a trusted server clock. On rollback we rebase the
        -- outstanding delay instead of granting time or freezing until the old
        -- wall clock catches up. This also handles a corrected device clock.
        session.NextRefillAt = now + math.max(0, session.NextRefillAt - session.ClockAt)
    end
    session.ClockAt = now
    if inventory.Balance >= config.RefillCap then
        session.NextRefillAt = nil
        return 0
    end
    if session.NextRefillAt == nil then
        session.NextRefillAt = now + config.RefillSeconds
        return 0
    end
    if now < session.NextRefillAt then
        return 0
    end
    local elapsedIntervals = math.floor((now - session.NextRefillAt) / config.RefillSeconds) + 1
    local granted = math.min(config.RefillCap - inventory.Balance, elapsedIntervals)
    inventory.Balance = inventory.Balance + granted
    if inventory.Balance >= config.RefillCap then
        session.NextRefillAt = nil
    else
        session.NextRefillAt = session.NextRefillAt + granted * config.RefillSeconds
    end
    return granted
end

function Session.Drop(session, count, now)
    Session.Advance(session, now)
    if not isInteger(count, 1, session.Config.MaxInventory) then
        return nil, "invalid_count"
    end
    local inventory = session.RewardState.balls.Data
    if inventory.Balance < count then
        return nil, "insufficient_balls"
    end
    if session.NextDropId > maxInteger - count then
        return nil, "session_limit"
    end

    local drops = {}
    for index = 1, count do
        local basketIndex = Random.WeightedIndex(session.Random,
            session.Config.Baskets, session.Config.TotalWeight)
        local basket = session.Config.Baskets[basketIndex]
        local drop = {
            Id = session.NextDropId,
            BasketId = basket.Id,
            BasketIndex = basketIndex,
            Rewards = Data.Copy(basket.Rewards),
            Seed = Random.NextSeed(session.Random),
            Phase = "InFlight",
        }
        session.NextDropId = session.NextDropId + 1
        session.Pending[#session.Pending + 1] = drop
        session.pendingIndices[drop.Id] = #session.Pending
        drops[index] = copyDrop(drop)
    end
    session.RandomState = session.Random.State
    inventory.Balance = inventory.Balance - count
    -- Spending below cap starts one interval now; there is no banked time from
    -- a full inventory. Spending during an interval preserves its deadline.
    Session.Advance(session, session.ClockAt)
    return drops
end

function Session.Land(session, dropId, now)
    local index = session.pendingIndices[dropId]
    if not index then return false end
    local drop = session.Pending[index]
    if drop.Phase == "Landed" then return false end
    Session.Advance(session, now or session.ClockAt)
    drop.Phase = "Landed"
    session.pendingRewardCount = session.pendingRewardCount + 1
    session.TotalHits = session.TotalHits + 1
    if session.BasketIndices[drop.BasketId] then
        session.HitsById[drop.BasketId] = (session.HitsById[drop.BasketId] or 0) + 1
    else
        session.ArchivedHits = session.ArchivedHits + 1
    end
    return true
end

function Session.Complete(session, dropId, now)
    -- Duplicate/late callbacks are harmless, including callbacks after reload.
    local index = session.pendingIndices[dropId]
    if not index then return nil end
    local drop = session.Pending[index]
    if drop.Phase ~= "Landed" then return nil, "not_landed" end
    Session.Advance(session, now or session.ClockAt)
    local awarded, rewardError = Registry.Apply(session.rewardRegistry, session.RewardState,
        drop.Rewards, session.Config)
    if not awarded then
        session.rewardFailures[dropId] = rewardError
        return nil, rewardError
    end
    -- Commit the complete reward pack before closing its ledger entry. Every
    -- handler worked on isolated data; no external side effects are allowed.
    session.RewardState = awarded
    session.rewardFailures[dropId] = nil
    local last = session.Pending[#session.Pending]
    -- The ledger is keyed by ID, not array order. Swap removal keeps completion
    -- constant-time as the number of simultaneous flights grows.
    session.Pending[index] = last
    session.pendingIndices[last.Id] = index
    session.Pending[#session.Pending] = nil
    session.pendingIndices[dropId] = nil
    session.SettledCount = session.SettledCount + 1
    session.pendingRewardCount = session.pendingRewardCount - 1
    Session.Advance(session, session.ClockAt)
    return copyDrop(drop)
end

function Session.Grant(session, now)
    Session.Advance(session, now)
    local inventory = session.RewardState.balls.Data
    local granted = math.max(0, math.min(session.Config.GrantSize, session.Config.MaxInventory - inventory.Balance))
    inventory.Balance = inventory.Balance + granted
    Session.Advance(session, session.ClockAt)
    return granted
end

function Session.Snapshot(session)
    local snapshot = {
        Version = Session.SnapshotVersion,
        RewardState = Data.Copy(session.RewardState),
        TotalHits = session.TotalHits,
        SettledCount = session.SettledCount,
        ArchivedHits = session.ArchivedHits,
        NextDropId = session.NextDropId,
        RandomState = session.Random.State,
        ClockAt = session.ClockAt,
        NextRefillAt = session.NextRefillAt,
        RefillSeconds = session.Config.RefillSeconds,
        HitsById = {},
        Pending = {},
    }
    for id, count in pairs(session.HitsById) do
        snapshot.HitsById[id] = count
    end
    for index, drop in ipairs(session.Pending) do
        snapshot.Pending[index] = copyDrop(drop)
    end
    return snapshot
end

function Session.View(session, includeDetails)
    -- Read-only projection. Time is advanced by commands/lifecycle/Update.
    local remaining = session.NextRefillAt and math.max(0, session.NextRefillAt - session.ClockAt) or 0
    local hits
    if includeDetails then
        hits = {}
        for index, basket in ipairs(session.Config.Baskets) do
            local count = session.HitsById[basket.Id] or 0
            hits[index] = {
                Id = basket.Id,
                Count = count,
                Percent = session.TotalHits > 0 and count * 100 / session.TotalHits or 0,
                WeightPercent = basket.Weight * 100 / session.Config.TotalWeight,
                Rewards = Data.Copy(basket.Rewards),
            }
        end
    end
    return {
        Balls = session.RewardState.balls.Data.Balance,
        Score = session.RewardState.points.Data.Balance,
        RewardState = includeDetails and Data.Copy(session.RewardState) or nil,
        RewardBlocked = next(session.rewardFailures) ~= nil,
        TotalHits = session.TotalHits,
        SettledCount = session.SettledCount,
        ArchivedHits = session.ArchivedHits,
        ActiveCount = #session.Pending,
        InFlightCount = #session.Pending - session.pendingRewardCount,
        PendingRewardCount = session.pendingRewardCount,
        RefillRemaining = remaining,
        RefillProgress = session.NextRefillAt and (1 - remaining / session.Config.RefillSeconds) or 1,
        Hits = hits,
    }
end

return Session
