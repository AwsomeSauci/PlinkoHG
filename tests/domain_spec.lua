-- Standalone Lua 5.1 / LuaJIT specification. No engine or third-party runner.
-- Run from the project root only when explicitly authorised:
--     lua tests/domain_spec.lua
local ConfigModule = require "scripts.domain.config"
local Registry = require "scripts.domain.rewards.registry"
local rewardRegistry = Registry.New(require "config.reward_types")
local Config = {Validate = function(raw) return ConfigModule.Validate(raw, rewardRegistry) end}
local Random = require "scripts.domain.random"
local Session = require "scripts.domain.session"
local SaveStore = require "scripts.infrastructure.save_store"
local sourceConfig = require "config.game"

local function complete(session, id, now)
    Session.Land(session, id, now)
    return Session.Complete(session, id, now)
end

local cases = {}

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, item in pairs(value) do
        result[key] = copy(item)
    end
    return result
end

local function equal(actual, expected, message)
    assert(actual == expected, (message or "Values differ")
        .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function near(actual, expected, tolerance)
    assert(math.abs(actual - expected) <= tolerance,
        "Expected " .. expected .. " +/- " .. tolerance .. ", got " .. actual)
end

local function configuration(overrides)
    local raw = copy(sourceConfig)
    for key, value in pairs(overrides or {}) do
        raw[key] = value
    end
    local config, validationError = Config.Validate(raw)
    assert(config, validationError)
    return config
end

local function test(name, callback)
    cases[#cases + 1] = { Name = name, Run = callback }
end

test("configuration validates and normalises without mutating source", function()
    local raw = copy(sourceConfig)
    raw.Baskets[1].Color = "abcdef"
    local config = assert(Config.Validate(raw))
    equal(config.TotalWeight, 100)
    equal(config.Baskets[1].Color, "ABCDEF")
    equal(raw.Baskets[1].Color, "abcdef")
    config.Baskets[1].Rewards[1].Amount = 99
    equal(raw.Baskets[1].Rewards[1].Amount, 100)
end)

test("invalid configuration is rejected before the game starts", function()
    local mutations = {
        function(raw) raw.Version = sourceConfig.Version + 1 end,
        function(raw) raw.RefillSeconds = 0 end,
        function(raw) raw.InitialBalls = -1 end,
        function(raw) raw.MaxInventory = 1 end,
        function(raw) raw.BatchSize = raw.MaxInventory + 1 end,
        function(raw) raw.Baskets[1].Weight = 0 / 0 end,
        function(raw) raw.Baskets[1].Weight = math.huge end,
        function(raw) raw.Baskets[1].Rewards[1].Amount = -1 end,
        function(raw) raw.Baskets[1].Color = "#ffffff" end,
        function(raw) raw.Baskets[2].Id = raw.Baskets[1].Id end,
        function(raw) raw.Baskets.Extra = {} end,
        function(raw) raw.Baskets[2] = nil end,
        function(raw)
            for basketIndex, basket in ipairs(raw.Baskets) do basket.Weight = 0 end
        end,
    }
    for index, mutate in ipairs(mutations) do
        local raw = copy(sourceConfig)
        mutate(raw)
        local result, validationError = Config.Validate(raw)
        equal(result, nil, "Invalid config mutation " .. index)
        assert(type(validationError) == "string")
    end
end)

test("basket count is data driven from two through sixteen", function()
    for count = 2, 16 do
        local baskets = {}
        for index = 1, count do
            baskets[index] = { Id = "basket" .. index, Weight = index, Rewards = {{Type = "points", Amount = index}}, Color = "FFFFFF" }
        end
        local config = configuration({ Baskets = baskets })
        local session = Session.New(config, 0, nil, rewardRegistry)
        equal(#Session.View(session, true).Hits, count)
    end
end)

test("PRNG matches the Park-Miller reference sequence", function()
    local random = { State = 1 }
    for index, expected in ipairs({ 16807, 282475249, 1622650073, 984943658, 1144108930 }) do
        equal(Random.NextSeed(random), expected)
    end
end)

test("zero-weight baskets are unreachable including trailing zeroes", function()
    local random = Random.New(73)
    local baskets = { { Weight = 0 }, { Weight = 7 }, { Weight = 0 } }
    for sampleIndex = 1, 1000 do
        equal(Random.WeightedIndex(random, baskets, 7), 2)
    end
end)

test("weighted sampling follows the configured distribution", function()
    local config = configuration()
    local random = Random.New(74129)
    local counts = {}
    local samples = 100000
    for sampleIndex = 1, samples do
        local index = Random.WeightedIndex(random, config.Baskets, config.TotalWeight)
        counts[index] = (counts[index] or 0) + 1
    end
    for index, basket in ipairs(config.Baskets) do
        near((counts[index] or 0) / samples, basket.Weight / config.TotalWeight, 0.006)
    end
end)

test("subnormal equal weights retain a fair distribution and scale invariance", function()
    local tiny = 5e-324
    assert(tiny > 0, "This specification requires IEEE-754 subnormal doubles")
    local config = configuration({ Baskets = {
        { Id = "first", Weight = tiny, Rewards = {{Type = "points", Amount = 1}}, Color = "FFFFFF" },
        { Id = "second", Weight = tiny, Rewards = {{Type = "points", Amount = 1}}, Color = "FFFFFF" },
        { Id = "disabled", Weight = 0, Rewards = {{Type = "points", Amount = 1}}, Color = "FFFFFF" },
    } })
    local ordinary = { { Weight = 1 }, { Weight = 1 }, { Weight = 0 } }
    local smallRandom = Random.New(92417)
    local ordinaryRandom = Random.New(92417)
    local firstCount = 0
    local samples = 20000
    for sampleIndex = 1, samples do
        local index = Random.WeightedIndex(smallRandom, config.Baskets, config.TotalWeight)
        equal(index, Random.WeightedIndex(ordinaryRandom, ordinary, 2),
            "Scaling equal weights must not change an outcome")
        if index == 1 then firstCount = firstCount + 1 end
    end
    near(firstCount / samples, 0.5, 0.02)
end)

test("refill has exact boundaries and retains fractional progress", function()
    local config = configuration()
    local session = Session.New(config, 100, nil, rewardRegistry)
    equal(Session.Advance(session, 129.5), 0)
    near(Session.View(session).RefillRemaining, 0.5, 0.0001)
    equal(Session.Advance(session, 130), 1)
    equal(session.RewardState.balls.Data.Balance, 13)
    equal(session.NextRefillAt, 160)
    equal(Session.Advance(session, 205), 2)
    equal(session.RewardState.balls.Data.Balance, 15)
    equal(session.NextRefillAt, 220)
end)

test("offline regeneration preserves the next deadline and stops at cap", function()
    local config = configuration()
    local session = Session.New(config, 100, nil, rewardRegistry)
    Session.Advance(session, 110)
    local restored = Session.New(config, 205, Session.Snapshot(session), rewardRegistry)
    equal(restored.RewardState.balls.Data.Balance, 15)
    equal(restored.NextRefillAt, 220)
    equal(Session.Advance(restored, 1000000), 5)
    equal(restored.RewardState.balls.Data.Balance, config.RefillCap)
    equal(restored.NextRefillAt, nil)
end)

test("full inventory cannot bank refill time", function()
    local config = configuration({ InitialBalls = 20 })
    local session = Session.New(config, 0, nil, rewardRegistry)
    Session.Advance(session, 10000)
    assert(Session.Drop(session, 1, 10000))
    equal(session.RewardState.balls.Data.Balance, 19)
    equal(session.NextRefillAt, 10030)
    equal(Session.Advance(session, 10029), 0)
    equal(Session.Advance(session, 10030), 1)
end)

test("spending while a refill is running does not restart its clock", function()
    local session = Session.New(configuration(), 0, nil, rewardRegistry)
    assert(Session.Drop(session, 5, 29))
    equal(session.NextRefillAt, 30)
    equal(Session.Advance(session, 30), 1)
    equal(session.RewardState.balls.Data.Balance, 8)
end)

test("clock rollback retains remaining delay without granting balls", function()
    local config = configuration()
    local session = Session.New(config, 100, nil, rewardRegistry)
    Session.Advance(session, 110)
    local restored = Session.New(config, 50, Session.Snapshot(session), rewardRegistry)
    equal(restored.RewardState.balls.Data.Balance, 12)
    equal(restored.NextRefillAt, 70)
    equal(Session.Advance(restored, 69), 0)
    equal(Session.Advance(restored, 70), 1)
end)

test("debug grants survive cap and only the hard limit restricts them", function()
    local config = configuration({ InitialBalls = 20, MaxInventory = 32 })
    local session = Session.New(config, 0, nil, rewardRegistry)
    equal(Session.Grant(session, 0), 10)
    equal(Session.Grant(session, 0), 2)
    equal(Session.Grant(session, 0), 0)
    equal(Session.Advance(session, 10000), 0)
    equal(session.RewardState.balls.Data.Balance, 32)
    equal(session.NextRefillAt, nil)
    assert(Session.Drop(session, 12, 10000))
    equal(session.NextRefillAt, nil)
    assert(Session.Drop(session, 1, 10000))
    equal(session.NextRefillAt, 10030)
end)

test("batch rejection is atomic and leaves the random sequence untouched", function()
    local session = Session.New(configuration({ InitialBalls = 3 }), 0, nil, rewardRegistry)
    local state = session.Random.State
    local drops, dropError = Session.Drop(session, 5, 0)
    equal(drops, nil)
    equal(dropError, "insufficient_balls")
    equal(session.RewardState.balls.Data.Balance, 3)
    equal(session.NextDropId, 1)
    equal(session.Random.State, state)
    equal(#session.Pending, 0)
end)

test("new drops remain available beyond the former 30 and 128 active limits", function()
    local session = Session.New(configuration({ InitialBalls = 4096 }), 0, nil, rewardRegistry)
    for batch = 1, 200 do assert(Session.Drop(session, 5, 0)) end
    equal(#session.Pending, 1000)
    assert(Session.Drop(session, 512, 0))
    assert(Session.Drop(session, 1, 0))
    equal(#session.Pending, 1513)
    equal(session.RewardState.balls.Data.Balance, 4096 - 1513)
    assert(Session.ValidateSnapshot(session.Config, Session.Snapshot(session), rewardRegistry))
end)

test("settlement is idempotent and updates points and actual percentages", function()
    local session = Session.New(configuration(), 0, nil, rewardRegistry)
    local drops = assert(Session.Drop(session, 2, 0))
    local first = assert(complete(session, drops[1].Id))
    equal(complete(session, drops[1].Id), nil)
    equal(complete(session, 999999), nil)
    equal(session.RewardState.points.Data.Balance, first.Rewards[1].Amount)
    equal(session.TotalHits, 1)
    equal(#session.Pending, 1)
    local view = Session.View(session, true)
    equal(view.Hits[first.BasketIndex].Count, 1)
    equal(view.Hits[first.BasketIndex].Percent, 100)
    local sum = 0
    for index, hit in ipairs(view.Hits) do sum = sum + hit.Percent end
    near(sum, 100, 0.00001)
end)

test("reload preserves paid pending outcomes and future random sequence", function()
    local config = configuration()
    local session = Session.New(config, 100, nil, rewardRegistry)
    local drops = assert(Session.Drop(session, 5, 100))
    complete(session, drops[1].Id)
    local restored = Session.New(config, 100, Session.Snapshot(session), rewardRegistry)
    equal(restored.RestoreError, nil)
    equal(restored.RewardState.balls.Data.Balance, 7)
    equal(#restored.Pending, 4)
    equal(complete(restored, drops[1].Id), nil)
    for index = 1, #session.Pending do
        equal(restored.Pending[index].BasketId, session.Pending[index].BasketId)
        equal(restored.Pending[index].Seed, session.Pending[index].Seed)
        equal(restored.Pending[index].Rewards[1].Amount, session.Pending[index].Rewards[1].Amount)
    end
    local nextOriginal = assert(Session.Drop(session, 1, 100))[1]
    local nextRestored = assert(Session.Drop(restored, 1, 100))[1]
    equal(nextOriginal.BasketId, nextRestored.BasketId)
    equal(nextOriginal.Seed, nextRestored.Seed)
    equal(nextOriginal.Id, nextRestored.Id)
end)

test("basket reordering and payout edits preserve already committed drops", function()
    local config = configuration()
    local session = Session.New(config, 0, nil, rewardRegistry)
    local drop = assert(Session.Drop(session, 1, 0))[1]
    local raw = copy(sourceConfig)
    local replacementIndex = drop.BasketIndex == 1 and 2 or 1
    raw.Baskets[drop.BasketIndex], raw.Baskets[replacementIndex] =
        raw.Baskets[replacementIndex], raw.Baskets[drop.BasketIndex]
    raw.Baskets[replacementIndex].Rewards[1].Amount = 999
    local restored = Session.New(assert(Config.Validate(raw)), 0, Session.Snapshot(session), rewardRegistry)
    equal(restored.Pending[1].BasketIndex, replacementIndex)
    equal(restored.Pending[1].Rewards[1].Amount, drop.Rewards[1].Amount)
    complete(restored, drop.Id)
    equal(restored.RewardState.points.Data.Balance, drop.Rewards[1].Amount)
end)

test("removed basket IDs archive history and settle without a new roll", function()
    local config = configuration()
    local session = Session.New(config, 0, nil, rewardRegistry)
    local drops = assert(Session.Drop(session, 2, 0))
    complete(session, drops[1].Id)
    local raw = copy(sourceConfig)
    for index, basket in ipairs(raw.Baskets) do basket.Id = "new_" .. basket.Id end
    local restored = Session.New(assert(Config.Validate(raw)), 0, Session.Snapshot(session), rewardRegistry)
    equal(restored.ArchivedHits, 1)
    equal(restored.Pending[1].BasketIndex, 0)
    equal(restored.Pending[1].BasketId, drops[2].BasketId)
    equal(restored.Random.State, session.Random.State)
    complete(restored, drops[2].Id)
    equal(restored.RewardState.points.Data.Balance, drops[1].Rewards[1].Amount + drops[2].Rewards[1].Amount)
    equal(restored.TotalHits, 2)
    equal(restored.ArchivedHits, 2)
    assert(Session.ValidateSnapshot(restored.Config, Session.Snapshot(restored), rewardRegistry))
end)

test("a large pending ledger restores every paid drop and allows further drops", function()
    local config = configuration({InitialBalls = 2048})
    local session = Session.New(config, 0, nil, rewardRegistry)
    assert(Session.Drop(session, 1024, 0))
    local restored = Session.New(config,
        0, Session.Snapshot(session), rewardRegistry)
    equal(restored.RestoreError, nil)
    equal(#restored.Pending, 1024)
    assert(Session.Drop(restored, 1024, 0))
    equal(#restored.Pending, 2048)
    equal(restored.RewardState.balls.Data.Balance, 0)
    assert(Session.ValidateSnapshot(config, Session.Snapshot(restored), rewardRegistry))
end)

test("out of order settlement keeps the pending index and reward total consistent", function()
    local session = Session.New(configuration(), 0, nil, rewardRegistry)
    local drops = assert(Session.Drop(session, 10, 0))
    local points = 0
    for position, index in ipairs({3, 7, 1, 10, 5, 2, 8, 4, 6, 9}) do
        assert(complete(session, drops[index].Id))
        equal(complete(session, drops[index].Id), nil)
        points = points + drops[index].Rewards[1].Amount
        equal(session.RewardState.points.Data.Balance, points)
        equal(#session.Pending, 10 - position)
        assert(Session.ValidateSnapshot(session.Config, Session.Snapshot(session), rewardRegistry))
    end
    equal(next(session.rewardFailures), nil)
    equal(next(session.pendingIndices), nil)
end)

test("removing the active cap retains exact integer protection at the ID boundary", function()
    local config = configuration()
    local snapshot = Session.Snapshot(Session.New(config, 0, nil, rewardRegistry))
    local maximum = 9007199254740991
    snapshot.TotalHits = maximum - 2
    snapshot.SettledCount = snapshot.TotalHits
    snapshot.NextDropId = maximum - 1
    snapshot.HitsById[config.Baskets[1].Id] = snapshot.TotalHits
    local session = Session.New(config, 0, snapshot, rewardRegistry)
    equal(session.RestoreError, nil)
    local drop = assert(Session.Drop(session, 1, 0))[1]
    local balls = session.RewardState.balls.Data.Balance
    local result, dropError = Session.Drop(session, 1, 0)
    equal(result, nil)
    equal(dropError, "session_limit")
    equal(session.RewardState.balls.Data.Balance, balls)
    assert(complete(session, drop.Id))
    assert(Session.ValidateSnapshot(config, Session.Snapshot(session), rewardRegistry))
end)

test("snapshot and returned drops do not expose mutable ledger tables", function()
    local session = Session.New(configuration(), 0, nil, rewardRegistry)
    local drop = assert(Session.Drop(session, 1, 0))[1]
    local expected = drop.Rewards[1].Amount
    drop.Rewards[1].Amount = 987654
    local snapshot = Session.Snapshot(session)
    snapshot.Pending[1].Rewards[1].Amount = 123456
    snapshot.RewardState.balls.Data.Balance = 999999
    equal(session.Pending[1].Rewards[1].Amount, expected)
    equal(session.RewardState.balls.Data.Balance, 11)
end)

test("corrupt saves are rejected as a whole", function()
    local config = configuration()
    local session = Session.New(config, 0, nil, rewardRegistry)
    assert(Session.Drop(session, 2, 0))
    local valid = Session.Snapshot(session)
    local mutations = {
        function(raw) raw.Version = Session.SnapshotVersion + 1 end,
        function(raw) raw.RewardState.balls.Data.Balance = "12" end,
        function(raw) raw.RewardState.points.Data.Balance = math.huge end,
        function(raw) raw.RandomState = 0 end,
        function(raw) raw.NextRefillAt = 100000 end,
        function(raw) raw.TotalHits = 7 end,
        function(raw) raw.NextDropId = 50 end,
        function(raw) raw.Pending[2].Id = raw.Pending[1].Id end,
        function(raw) raw.Pending[2].Rewards[1].Amount = -1 end,
        function(raw) raw.Pending.Extra = {} end,
    }
    for index, mutate in ipairs(mutations) do
        local invalid = copy(valid)
        mutate(invalid)
        local snapshot, validationError = Session.ValidateSnapshot(config, invalid, rewardRegistry)
        equal(snapshot, nil, "Invalid snapshot mutation " .. index)
        assert(type(validationError) == "string")
    end
end)

local function memoryBackend()
    local files = {}
    local backend = {
        Path = function(self, application, filename)
            return application .. "/" .. filename
        end,
        Read = function(self, path)
            return {Status = files[path] and "loaded" or "missing", Value = copy(files[path])}
        end,
        Write = function(self, path, value)
            files[path] = copy(value)
            return true
        end,
    }
    return backend, files
end

test("storage alternates slots and falls back from an invalid newer save", function()
    local config = configuration()
    local backend, files = memoryBackend()
    local store = SaveStore.New(config, backend, rewardRegistry)
    local empty, emptyError = SaveStore.Load(store)
    equal(empty, nil)
    equal(emptyError, nil)
    local session = Session.New(config, 0, nil, rewardRegistry)
    assert(SaveStore.Save(store, Session.Snapshot(session)))
    equal(store.Slot, 1)
    assert(Session.Drop(session, 1, 0))
    assert(SaveStore.Save(store, Session.Snapshot(session)))
    equal(store.Slot, 2)
    equal(store.Revision, 2)
    files[store.Paths[2]].Payload.RewardState.balls.Data.Balance = "corrupted"
    local recovered = SaveStore.New(config, backend, rewardRegistry)
    local snapshot, warning = SaveStore.Load(recovered)
    assert(snapshot)
    assert(warning)
    equal(recovered.Revision, 1)
    equal(snapshot.RewardState.balls.Data.Balance, config.InitialBalls)
    assert(SaveStore.Save(recovered, snapshot))
    equal(recovered.Slot, 2)
    equal(recovered.Revision, 2)
end)

test("future envelope and payload schemas preserve both slots and block downgrade", function()
    for caseIndex, layer in ipairs({ "Envelope", "Payload" }) do
        local config = configuration()
        local backend, files = memoryBackend()
        local store = SaveStore.New(config, backend, rewardRegistry)
        local current = Session.Snapshot(Session.New(config, 0, nil, rewardRegistry))
        assert(SaveStore.Save(store, current))
        local original = files[store.Paths[1]]
        local future = {
            Version = layer == "Envelope" and SaveStore.Version + 1 or SaveStore.Version,
            Revision = 2,
            Payload = copy(current),
            FutureMarker = "Preserve data owned by the newer application",
        }
        if layer == "Payload" then future.Payload.Version = Session.SnapshotVersion + 1 end
        files[store.Paths[2]] = future

        local downgraded = SaveStore.New(config, backend, rewardRegistry)
        local loaded, loadError = SaveStore.Load(downgraded)
        equal(loaded, nil, "Future " .. layer .. " must prevent fallback")
        assert(loadError:find("newer", 1, true))
        equal(downgraded.Error, loadError)
        local saved, saveError = SaveStore.Save(downgraded, current)
        equal(saved, false)
        equal(saveError, loadError)
        equal(files[store.Paths[1]], original)
        equal(files[store.Paths[2]], future)
        equal(future.FutureMarker, "Preserve data owned by the newer application")
    end
end)

test("failed writes preserve the previous revision and last good slot", function()
    local config = configuration()
    local backend, files = memoryBackend()
    local store = SaveStore.New(config, backend, rewardRegistry)
    local session = Session.New(config, 0, nil, rewardRegistry)
    assert(SaveStore.Save(store, Session.Snapshot(session)))
    backend.Write = function(self, path)
        files[path] = { Version = SaveStore.Version, Revision = 2, Payload = {} }
        error("Disk full")
    end
    local saved, saveError = SaveStore.Save(store, Session.Snapshot(session))
    equal(saved, false)
    assert(saveError:find("Disk full", 1, true))
    equal(store.Revision, 1)
    equal(store.Slot, 1)
    local snapshot = assert(SaveStore.Load(SaveStore.New(config, backend, rewardRegistry)))
    equal(snapshot.RewardState.balls.Data.Balance, session.RewardState.balls.Data.Balance)
end)

test("save path and load exceptions are surfaced without crashing", function()
    local config = configuration()
    local backend = memoryBackend()
    backend.Path = function() error("Unavailable path") end
    local store = SaveStore.New(config, backend, rewardRegistry)
    local saved, saveError = SaveStore.Save(store, {})
    equal(saved, false)
    assert(saveError:find("Unavailable path", 1, true))
    backend = memoryBackend()
    backend.Read = function() error("Unreadable file") end
    local snapshot, loadError = SaveStore.Load(SaveStore.New(config, backend, rewardRegistry))
    equal(snapshot, nil)
    assert(loadError:find("Unreadable file", 1, true))
end)

test("unreadable slot blocks all writes even when another valid slot exists", function()
    for lockedSlot = 1, 2 do
        local config = configuration()
        local backend, files = memoryBackend()
        local original = SaveStore.New(config, backend, rewardRegistry)
        local snapshot = Session.Snapshot(Session.New(config, 0, nil, rewardRegistry))
        snapshot.RewardState.points.Data.Balance = 900
        assert(SaveStore.Save(original, snapshot)); assert(SaveStore.Save(original, snapshot))
        local a, b = files[original.Paths[1]], files[original.Paths[2]]
        local read = backend.Read
        backend.Read = function(self, path)
            if path == original.Paths[lockedSlot] then return {Status = "unavailable", Error = "Sharing violation"} end
            return read(self, path)
        end
        local blocked = SaveStore.New(config, backend, rewardRegistry)
        local loaded, err = SaveStore.Load(blocked)
        equal(loaded, nil); assert(err:find("Sharing violation", 1, true))
        backend.Read = read -- an unread store cannot become writable after unlock
        equal(SaveStore.Save(blocked, snapshot), false)
        equal(files[original.Paths[1]], a); equal(files[original.Paths[2]], b)
        local recovered = assert(SaveStore.Load(SaveStore.New(config, backend, rewardRegistry)))
        equal(recovered.RewardState.points.Data.Balance, 900)
    end
end)

test("empty existing envelopes are corruption, never proof of a new game", function()
    local config = configuration()
    local backend, files = memoryBackend()
    local store = SaveStore.New(config, backend, rewardRegistry)
    files[store.Paths[1]], files[store.Paths[2]] = {}, {}
    local loaded, err = SaveStore.Load(store)
    equal(loaded, nil); assert(err)
    equal(SaveStore.Save(store, Session.Snapshot(Session.New(config, 0, nil, rewardRegistry))), false)
    equal(next(files[store.Paths[1]]), nil); equal(next(files[store.Paths[2]]), nil)
end)

test("external save revisions and deletions are detected before a stale store writes", function()
    local config = configuration()
    local backend, files = memoryBackend()
    local a = SaveStore.New(config, backend, rewardRegistry)
    local snapshot = Session.Snapshot(Session.New(config, 0, nil, rewardRegistry))
    assert(SaveStore.Save(a, snapshot))
    local b = SaveStore.New(config, backend, rewardRegistry)
    assert(SaveStore.Load(b))
    snapshot.RewardState.points.Data.Balance = 900
    assert(SaveStore.Save(a, snapshot))
    local beforeA, beforeB = files[a.Paths[1]], files[a.Paths[2]]
    local saved, err, status = SaveStore.Save(b, snapshot)
    equal(saved, false); equal(status, "conflict"); assert(err)
    equal(files[a.Paths[1]], beforeA); equal(files[a.Paths[2]], beforeB)
    files[a.Paths[1]], files[a.Paths[2]] = nil, nil
    saved, err, status = SaveStore.Save(a, snapshot)
    equal(saved, false); equal(status, "conflict"); equal(next(files), nil)
end)

test("landing and payout are separate idempotent domain facts", function()
    local config = configuration()
    local session = Session.New(config, 0, nil, rewardRegistry)
    local drop = assert(Session.Drop(session, 1, 0))[1]
    local result, err = Session.Complete(session, drop.Id, 0)
    equal(result, nil); equal(err, "not_landed"); equal(session.TotalHits, 0)
    assert(Session.Land(session, drop.Id, 0)); equal(Session.Land(session, drop.Id, 0), false)
    local view = Session.View(session, true)
    equal(view.TotalHits, 1); equal(view.SettledCount, 0); equal(view.InFlightCount, 0)
    equal(view.PendingRewardCount, 1); equal(view.Score, 0); equal(view.Hits[drop.BasketIndex].Percent, 100)
    local restored = Session.New(config, 0, Session.Snapshot(session), rewardRegistry)
    equal(Session.Land(restored, drop.Id, 0), false)
    assert(Session.Complete(restored, drop.Id, 0))
    equal(Session.Complete(restored, drop.Id, 0), nil); equal(Session.Land(restored, drop.Id, 0), false)
    equal(restored.TotalHits, 1); equal(restored.SettledCount, 1)
    assert(Session.ValidateSnapshot(config, Session.Snapshot(restored), rewardRegistry))
end)

test("snapshot rejects contradictory phases, settlement counts and per-basket landing facts", function()
    local config = configuration()
    local session = Session.New(config, 0, nil, rewardRegistry)
    local drop = assert(Session.Drop(session, 1, 0))[1]
    assert(Session.Land(session, drop.Id, 0))
    local saved = Session.Snapshot(session)
    local other = config.Baskets[drop.BasketIndex == 1 and 2 or 1].Id
    for index, mutate in ipairs({
        function(s) s.Pending[1].Phase = nil end,
        function(s) s.Pending[1].Phase = "InFlight" end,
        function(s) s.SettledCount = 1 end,
        function(s) s.HitsById[drop.BasketId] = 0; s.HitsById[other] = 1 end,
    }) do
        local invalid = copy(saved); mutate(invalid)
        equal(Session.ValidateSnapshot(config, invalid, rewardRegistry), nil)
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
    error(tostring(failures) .. " domain specifications failed")
end
