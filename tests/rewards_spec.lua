-- Extension contracts and transactional payouts; runs without Defold globals.
local Config = require "scripts.domain.config"
local Session = require "scripts.domain.session"
local Registry = require "scripts.domain.rewards.registry"
local Data = require "scripts.domain.rewards.data"
local SaveStore = require "scripts.infrastructure.save_store"
local RewardText = require "scripts.ui.reward_text"
local Strings = require "scripts.ui.strings"
local registrations = require "config.reward_types"
local source = require "config.game"
local registries = {}
local function complete(session, id, now)
    Session.Land(session, id, now)
    return Session.Complete(session, id, now)
end

local cases = {}
local function test(name, run) cases[#cases + 1] = {Name = name, Run = run} end
local function equal(actual, expected)
    assert(actual == expected, "Expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function configuration(rewards, extra, overrides)
    local types = {}
    for index, entry in ipairs(registrations) do types[index] = entry end
    if extra then types[#types + 1] = extra end
    local raw = Data.Copy(source)
    for key, value in pairs(overrides or {}) do raw[key] = value end
    for index, basket in ipairs(raw.Baskets) do
        basket.Weight = index == 1 and 1 or 0
        basket.Rewards = Data.Copy(rewards)
    end
    local registry = Registry.New(types)
    local config = assert(Config.Validate(raw, registry))
    registries[config] = registry
    return config, types
end
local function mixed()
    return {{Type = "points", Amount = 100}, {Type = "balls", Amount = 2},
        {Type = "item", ItemId = "leaf", Name = "Лист", Amount = 3}}
end
local function memory()
    local files = {}
    return {
        Path = function(self, app, name) return app .. "/" .. name end,
        Read = function(self, path) return {Status = files[path] and "loaded" or "missing", Value = Data.Copy(files[path])} end,
        Write = function(self, path, value) files[path] = Data.Copy(value); return true end,
    }, files
end

-- A fourth type with a different state shape. Neither Session, Config,
-- SaveStore, HUD nor the built-in handlers know about this type.
local function unlockType()
    return {Type = "unlock", Handler = {
        Version = 1,
        Normalize = function(reward)
            if not Data.Id(reward.Key) then return nil, "Invalid unlock key" end
            return {Key = reward.Key}
        end,
        NewState = function() return {Unlocked = {}} end,
        ValidateState = function(state)
            if type(state) ~= "table" or type(state.Unlocked) ~= "table" then return nil, "Invalid unlock state" end
            for key, value in pairs(state.Unlocked) do
                if not Data.Id(key) or value ~= true then return nil, "Invalid unlock entry" end
            end
            return state
        end,
        Apply = function(state, reward) state.Unlocked[reward.Key] = true; return true end,
    }, View = {
        Format = function(reward) return "Открыто: " .. reward.Key end,
        Balance = function(state) return state.Unlocked.forest and "Лес открыт" or nil end,
    }}
end

test("mixed rewards commit every balance and exactly one hit", function()
    local config = configuration(mixed())
    local session = Session.New(config, 0, nil, registries[config])
    local drop = assert(Session.Drop(session, 1, 0))[1]
    equal(Session.View(session).Balls, 11)
    assert(complete(session, drop.Id, 0))
    local view = Session.View(session, true)
    equal(view.Score, 100); equal(view.Balls, 13); equal(view.TotalHits, 1)
    equal(view.RewardState.item.Data.Counts.leaf, 3)
    equal(complete(session, drop.Id, 0), nil)
    equal(Session.View(session).Score, 100)
    equal(session.RewardState.item.Data.Counts.leaf, 3)
end)

test("capacity rejection keeps the whole pack pending until spending permits retry", function()
    local rewards = mixed(); rewards[2].Amount = 5
    local config = configuration(rewards, nil, {InitialBalls = 19, MaxInventory = 20})
    local session = Session.New(config, 0, nil, registries[config])
    local drop = assert(Session.Drop(session, 1, 0))[1]
    local completed, err = complete(session, drop.Id, 0)
    equal(completed, nil); assert(err)
    local view = Session.View(session, true)
    equal(view.Score, 0); equal(view.Balls, 18); equal(view.TotalHits, 1); equal(view.SettledCount, 0)
    equal(view.RewardState.item.Data.Counts.leaf, nil); assert(view.RewardBlocked)
    assert(Session.Drop(session, 3, 0))
    assert(complete(session, drop.Id, 0))
    view = Session.View(session, true)
    equal(view.Score, 100); equal(view.Balls, 20); equal(view.ActiveCount, 3)
    equal(view.RewardState.item.Data.Counts.leaf, 3); equal(session.NextRefillAt, nil)
    assert(not view.RewardBlocked)
end)

test("throwing extension cannot leak earlier awards or its own partial mutation", function()
    local extension = unlockType()
    local fail = true
    extension.Handler.Apply = function(state, reward)
        state.Unlocked[reward.Key] = true
        if fail then error("Injected failure after mutation") end
        return true
    end
    local config = configuration({{Type = "points", Amount = 7}, {Type = "unlock", Key = "forest"}}, extension)
    local session = Session.New(config, 0, nil, registries[config])
    local drop = assert(Session.Drop(session, 1, 0))[1]
    local result, err = complete(session, drop.Id, 0)
    equal(result, nil); assert(err:find("Injected failure", 1, true))
    equal(session.RewardState.points.Data.Balance, 0)
    equal(session.RewardState.unlock.Data.Unlocked.forest, nil)
    equal(#session.Pending, 1); equal(session.TotalHits, 1); equal(session.SettledCount, 0)
    fail = false
    assert(complete(session, drop.Id, 0))
    equal(session.RewardState.points.Data.Balance, 7)
    equal(session.RewardState.unlock.Data.Unlocked.forest, true)
end)

test("handler success with invalid state also rolls back the entire pack", function()
    local extension = unlockType()
    extension.Handler.Apply = function(state) state.Unlocked.invalid = 42; return true end
    local config = configuration({{Type = "points", Amount = 7}, {Type = "unlock", Key = "forest"}}, extension)
    local session = Session.New(config, 0, nil, registries[config])
    local drop = assert(Session.Drop(session, 1, 0))[1]
    equal(complete(session, drop.Id, 0), nil)
    equal(session.RewardState.points.Data.Balance, 0)
    equal(next(session.RewardState.unlock.Data.Unlocked), nil)
    equal(#session.Pending, 1)
end)

test("fourth type needs only registration, handler and formatter across save and restore", function()
    local config, types = configuration({{Type = "unlock", Key = "forest"}}, unlockType())
    local session = Session.New(config, 0, nil, registries[config])
    local drop = assert(Session.Drop(session, 1, 0))[1]
    local backend = memory()
    local store = SaveStore.New(config, backend, registries[config])
    assert(store.Paths[1]:find("session-v3-a", 1, true))
    assert(SaveStore.Save(store, Session.Snapshot(session)))
    local restored = Session.New(config, 0, assert(SaveStore.Load(SaveStore.New(config, backend, registries[config]))), registries[config])
    local result = assert(complete(restored, drop.Id, 0))
    assert(SaveStore.Save(store, Session.Snapshot(restored)))
    local again = Session.New(config, 0, assert(SaveStore.Load(SaveStore.New(config, backend, registries[config]))), registries[config])
    equal(again.RewardState.unlock.Data.Unlocked.forest, true)
    equal(again.TotalHits, 1); equal(#again.Pending, 0)
    local formatter = RewardText.New(types, Strings.New("ru"))
    equal(RewardText.Format(formatter, result.Rewards, "full"), "Открыто: forest")
    equal(RewardText.Balances(formatter, again.RewardState), "Лес открыт")
end)

test("new optional namespaces initialize while missing core balances are rejected", function()
    local config = configuration(mixed())
    local snapshot = Session.Snapshot(Session.New(config, 0, nil, registries[config]))
    local extended = configuration(mixed(), unlockType())
    local restored = assert(Session.ValidateSnapshot(extended, snapshot, registries[extended]))
    equal(next(restored.RewardState.unlock.Data.Unlocked), nil)
    snapshot.RewardState.balls = nil
    equal(Session.ValidateSnapshot(extended, snapshot, registries[extended]), nil)
end)

test("committed pack survives changed config, deleted basket and caller mutation", function()
    local config = configuration(mixed())
    local session = Session.New(config, 0, nil, registries[config])
    local drop = assert(Session.Drop(session, 1, 0))[1]
    drop.Rewards[1].Amount = 999
    config.Baskets[1].Rewards[2].Amount = 99
    local snapshot = Session.Snapshot(session)
    local changed = configuration({{Type = "points", Amount = 1}})
    changed.Baskets[1].Id = "replacement"
    local restored = Session.New(changed, 0, snapshot, registries[changed])
    equal(restored.Pending[1].BasketIndex, 0)
    assert(complete(restored, drop.Id, 0))
    equal(Session.View(restored).Score, 100)
    equal(Session.View(restored).Balls, 13)
    equal(restored.RewardState.item.Data.Counts.leaf, 3)
    equal(restored.ArchivedHits, 1)
    snapshot.Pending[1].Rewards[3].Name = "Changed"
    equal(restored.RewardState.item.Data.Names.leaf, "Лист")
end)

test("item stacks and display names survive real adapter roundtrip", function()
    local config = configuration({{Type = "item", ItemId = "leaf", Name = "Лист", Amount = 2},
        {Type = "item", ItemId = "leaf", Name = "Лист", Amount = 3}})
    local session = Session.New(config, 0, nil, registries[config])
    for index, drop in ipairs(assert(Session.Drop(session, 2, 0))) do assert(complete(session, drop.Id, 0)) end
    local backend = memory()
    assert(SaveStore.Save(SaveStore.New(config, backend, registries[config]), Session.Snapshot(session)))
    local restored = assert(SaveStore.Load(SaveStore.New(config, backend, registries[config])))
    equal(restored.RewardState.item.Data.Counts.leaf, 10)
    equal(restored.RewardState.item.Data.Names.leaf, "Лист")
end)

test("unknown saved types and versions block fallback and preserve both slots", function()
    for index, mutate in ipairs({
        function(s) s.RewardState.future = {Version = 1, Data = {}} end,
        function(s) s.RewardState.item.Version = 2 end,
        function(s) s.Pending[1].Rewards[1].Type = "future" end,
        function(s) s.Pending[1].Rewards[1].Version = 2 end,
    }) do
        local config = configuration(mixed())
        local backend, files = memory()
        local store, session = SaveStore.New(config, backend, registries[config]), Session.New(config, 0, nil, registries[config])
        assert(SaveStore.Save(store, Session.Snapshot(session)))
        assert(Session.Drop(session, 1, 0))
        assert(SaveStore.Save(store, Session.Snapshot(session)))
        mutate(files[store.Paths[2]].Payload)
        local first, second = files[store.Paths[1]], files[store.Paths[2]]
        local reopened = SaveStore.New(config, backend, registries[config])
        local snapshot, err = SaveStore.Load(reopened)
        equal(snapshot, nil); assert(err and reopened.Error)
        equal(SaveStore.Save(reopened, Session.Snapshot(session)), false)
        equal(files[store.Paths[1]], first); equal(files[store.Paths[2]], second)
    end
end)

test("reward validation rejects unknown, malformed and infeasible packs", function()
    local invalid = {
        {}, {{Type = "unknown", Amount = 1}}, {{Type = "points", Amount = -1}},
        {{Type = "points", Amount = 0 / 0}}, {{Type = "balls", Amount = 21}},
        {{Type = "balls", Amount = 11}, {Type = "balls", Amount = 10}},
        {{Type = "item", ItemId = "bad id", Name = "Leaf", Amount = 1}},
        {{Type = "item", ItemId = "leaf", Name = "Bad\nName", Amount = 1}},
        {[1] = {Type = "points", Amount = 1}, [3] = {Type = "points", Amount = 1}},
    }
    local registry = Registry.New(registrations)
    local hole = {{Type = "points", Amount = 1}, {Type = "points", Amount = 2}, {Type = "points", Amount = 3}}
    hole[2] = nil
    invalid[#invalid + 1] = hole
    for index, rewards in ipairs(invalid) do
        local raw = Data.Copy(source)
        raw.MaxInventory = 20; raw.Baskets[1].Rewards = rewards
        equal(Config.Validate(raw, registry), nil)
    end
    local raw = Data.Copy(source); raw.Baskets[1].Points = 5
    equal(Config.Validate(raw, registry), nil)
end)

test("normalization isolates input and rejects executable or cyclic data", function()
    local extension = unlockType()
    local original = extension.Handler.Normalize
    extension.Handler.Normalize = function(reward)
        local result = original(reward); reward.Key = "mutated"; return result
    end
    local config = configuration({{Type = "unlock", Key = "forest"}}, extension)
    equal(config.Baskets[1].Rewards[1].Key, "forest")
    for index, bad in ipairs({function() end, setmetatable({}, {}), math.huge}) do
        extension.Handler.Normalize = function() return {Bad = bad} end
        equal(Registry.Normalize(registries[config], {{Type = "unlock", Key = "forest"}}, config), nil)
    end
    local cycle = {}; cycle.Child = cycle
    extension.Handler.Normalize = function() return cycle end
    equal(Registry.Normalize(registries[config], {{Type = "unlock", Key = "forest"}}, config), nil)
end)

test("lowering inventory capacity preserves owned and previously promised rewards", function()
    local config = configuration({{Type = "balls", Amount = 25}}, nil, {InitialBalls = 30})
    local session = Session.New(config, 0, nil, registries[config])
    local drop = assert(Session.Drop(session, 1, 0))[1]
    local changed = configuration({{Type = "points", Amount = 1}}, nil, {MaxInventory = 20})
    local restored = Session.New(changed, 0, Session.Snapshot(session), registries[changed])
    equal(restored.RestoreError, nil); equal(Session.View(restored).Balls, 29)
    equal(restored.Pending[1].Rewards[1].Amount, 25)
    equal(complete(restored, drop.Id, 0), nil)
    equal(#restored.Pending, 1)
    equal(Session.Grant(restored, 0), 0)
end)

test("exact integer overflow never closes or partially pays a drop", function()
    for index, name in ipairs({"points", "item"}) do
        local config = configuration(mixed())
        local session = Session.New(config, 0, nil, registries[config])
        if name == "points" then session.RewardState.points.Data.Balance = Data.MaxInteger
        else session.RewardState.item.Data = {Counts = {leaf = Data.MaxInteger}, Names = {leaf = "Лист"}} end
        local drop = assert(Session.Drop(session, 1, 0))[1]
        equal(complete(session, drop.Id, 0), nil)
        equal(Session.View(session).Balls, 11)
        equal(session.TotalHits, 1); equal(session.SettledCount, 0); equal(#session.Pending, 1)
        if name == "item" then equal(Session.View(session).Score, 0) end
    end
end)

test("Russian reward amounts use readable singular and plural forms", function()
    local text = Strings.New("ru")
    for index, pair in ipairs({{1, "1 шар"}, {2, "2 шара"}, {5, "5 шаров"},
        {11, "11 шаров"}, {21, "21 шар"}, {112, "112 шаров"}}) do
        equal(text("RewardBalls", pair[1]), pair[2])
    end
    equal(text("RewardPoints", 22), "22 очка")
    equal(Strings.New("en")("RewardPoints", 5), "5 points")
end)

test("presentation validates its contract and cannot mutate game definitions", function()
    local extension = unlockType()
    extension.View.Format = function(reward) reward.Key = "changed"; return "Preview" end
    local config, types = configuration({{Type = "unlock", Key = "forest"}}, extension)
    local formatter = RewardText.New(types, Strings.New("ru"), config)
    equal(RewardText.Format(formatter, config.Baskets[1].Rewards, "full"), "Preview")
    equal(config.Baskets[1].Rewards[1].Key, "forest")
    extension.View.Format = function() return {} end
    equal(pcall(RewardText.New, types, Strings.New("ru"), config), false)
    equal(pcall(Registry.New, {[1] = registrations[1], [3] = registrations[2]}), false)
end)

local failures = 0
for index, case in ipairs(cases) do
    local ok, err = pcall(case.Run)
    if not ok then failures = failures + 1 end
    io.write(ok and "PASS " or "FAIL ", case.Name, ok and "\n" or ": " .. tostring(err) .. "\n")
end
io.write(#cases - failures, "/", #cases, " reward specifications passed\n")
assert(failures == 0, tostring(failures) .. " reward specifications failed")
