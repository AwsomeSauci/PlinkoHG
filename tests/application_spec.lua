local Game = require "scripts.application.game"
local Config = require "scripts.domain.config"
local Registry = require "scripts.domain.rewards.registry"
local Data = require "scripts.domain.rewards.data"
local Session = require "scripts.domain.session"
local source = require "config.game"
local rewardRegistry = Registry.New(require "config.reward_types")
local cases = {}
local function test(name, run) cases[#cases + 1] = {Name = name, Run = run} end
local function equal(a, b) assert(a == b, tostring(a) .. " ~= " .. tostring(b)) end
local function config(rewards)
    local raw = Data.Copy(source)
    raw.MaxInventory = 20
    for index, basket in ipairs(raw.Baskets) do
        basket.Weight = index == 1 and 1 or 0
        basket.Rewards = rewards or {{Type = "points", Amount = 10}}
    end
    return assert(Config.Validate(raw, rewardRegistry))
end
local function events(game, kind)
    local result = {}
    for index, event in ipairs(Game.DrainEvents(game)) do
        if event.Kind == kind then result[#result + 1] = event end
    end
    return result
end

local function commit(game, now)
    local checkpoint = Game.Checkpoint(game, now or 0)
    Game.Confirm(game, checkpoint)
    return checkpoint.Snapshot
end

test("playback starts only after acknowledgement of the debit checkpoint", function()
    local game = Game.New(config(), 0, nil, rewardRegistry)
    assert(Game.Drop(game, 1, 0))
    equal(#events(game, "Started"), 0)
    Game.Land(game, 1, 0); equal(Game.View(game).TotalHits, 0)
    local saved = commit(game)
    equal(saved.RewardState.balls.Data.Balance, 11); equal(#saved.Pending, 1)
    local started = events(game, "Started")[1].Drop
    equal(started.Id, saved.Pending[1].Id); equal(started.Seed, saved.Pending[1].Seed)
    equal(started.Rewards, nil)
    started.Id = 99; equal(Game.View(game).ActiveCount, 1)
end)

test("an old checkpoint cannot release an outcome created after its capture", function()
    local game = Game.New(config(), 0, nil, rewardRegistry)
    assert(Game.Drop(game, 1, 0))
    local checkpoint = Game.Checkpoint(game, 0)
    assert(Game.Drop(game, 1, 0))
    Game.Confirm(game, checkpoint)
    local started = events(game, "Started")
    equal(#started, 1); equal(started[1].Drop.Id, 1); assert(Game.NeedsCheckpoint(game))
    Game.Land(game, 2, 0); equal(Game.View(game).TotalHits, 0)
    commit(game); equal(events(game, "Started")[1].Drop.Id, 2)
end)

test("multiple landings coalesce into one snapshot without duplicate awards", function()
    local game = Game.New(config(), 0, nil, rewardRegistry)
    assert(Game.Drop(game, 5, 0)); commit(game)
    for index, event in ipairs(events(game, "Started")) do
        Game.Land(game, event.Drop.Id, 0); Game.Land(game, event.Drop.Id, 0)
    end
    equal(#events(game, "Awarded"), 5)
    local saved = commit(game)
    equal(saved.TotalHits, 5); equal(#saved.Pending, 0); equal(saved.RewardState.points.Data.Balance, 50)
end)

test("restart before payout checkpoint replays the original paid outcome once", function()
    local game = Game.New(config(), 0, nil, rewardRegistry)
    assert(Game.Drop(game, 1, 0))
    local saved = commit(game)
    local first = events(game, "Started")[1].Drop
    Game.Land(game, first.Id, 0)
    equal(Game.View(game).Score, 10); equal(saved.TotalHits, 0)
    local restored = Game.New(config(), 0, saved, rewardRegistry)
    commit(restored)
    local replay = events(restored, "Started")[1].Drop
    equal(replay.Id, first.Id); equal(replay.Seed, first.Seed)
    Game.Land(restored, replay.Id, 0)
    saved = commit(restored)
    equal(saved.TotalHits, 1); equal(saved.RewardState.points.Data.Balance, 10)
    equal(saved.RewardState.balls.Data.Balance, 11)
end)

test("blocked composite rewards retry independently of released flight visuals", function()
    local game = Game.New(config({{Type = "points", Amount = 10}, {Type = "balls", Amount = 10}}), 0, nil, rewardRegistry)
    assert(Game.Drop(game, 1, 0)); commit(game)
    local drop = events(game, "Started")[1].Drop
    Game.Land(game, drop.Id, 0)
    equal(#events(game, "RewardFailed"), 1); assert(Game.View(game).RewardBlocked)
    equal(Game.View(game).Score, 0); equal(Game.View(game).TotalHits, 1)
    Game.Land(game, drop.Id, 0); equal(#Game.DrainEvents(game), 0)
    assert(Game.Drop(game, 1, 0)); commit(game); events(game, "Started")
    Game.Update(game, 0, 1)
    equal(#events(game, "Awarded"), 1)
    local view = Game.View(game)
    equal(view.Score, 10); equal(view.Balls, 20); equal(view.ActiveCount, 1)
    assert(not view.RewardBlocked)
end)

test("removed basket pays without a flight and retains its original reward", function()
    local original = config({{Type = "item", ItemId = "leaf", Name = "Лист", Amount = 2}})
    local session = Session.New(original, 0, nil, rewardRegistry)
    assert(Session.Drop(session, 1, 0))
    local changed = config(); changed.Baskets[1].Id = "replacement"
    local game = Game.New(changed, 0, Session.Snapshot(session), rewardRegistry)
    commit(game); equal(#events(game, "Started"), 0)
    Game.Update(game, 0, 1)
    equal(#events(game, "Awarded"), 1)
    local saved = commit(game)
    equal(saved.RewardState.item.Data.Counts.leaf, 2); equal(saved.ArchivedHits, 1); equal(#saved.Pending, 0)
end)

test("acknowledging an older snapshot preserves newer landing and payout changes", function()
    local game = Game.New(config(), 0, nil, rewardRegistry)
    assert(Game.Drop(game, 1, 0)); commit(game)
    local drop = events(game, "Started")[1].Drop
    local old = Game.Checkpoint(game, 0)
    Game.Land(game, drop.Id, 0); Game.DrainEvents(game)
    Game.Confirm(game, old)
    assert(Game.NeedsCheckpoint(game)); equal(Game.View(game).Score, 10)
    equal(#Game.DrainEvents(game), 0)
    local current = commit(game)
    equal(current.SettledCount, 1); equal(current.RewardState.points.Data.Balance, 10)
    assert(not Game.NeedsCheckpoint(game))
    Game.Land(game, drop.Id, 0); equal(Game.View(game).Score, 10)
end)

test("invalid restore fails closed", function()
    equal(pcall(Game.New, config(), 0, {Version = Session.SnapshotVersion}, rewardRegistry), false)
end)

test("blocked landed payout restores without replay or counting the hit twice", function()
    local cfg = config({{Type = "points", Amount = 100}, {Type = "balls", Amount = 10}})
    local game = Game.New(cfg, 0, nil, rewardRegistry)
    assert(Game.Drop(game, 1, 0)); commit(game)
    local drop = events(game, "Started")[1].Drop
    Game.Land(game, drop.Id, 0)
    local saved = commit(game)
    equal(saved.TotalHits, 1); equal(saved.SettledCount, 0); equal(saved.Pending[1].Phase, "Landed")
    local restored = Game.New(cfg, 0, saved, rewardRegistry)
    commit(restored); equal(#events(restored, "Started"), 0)
    Game.Land(restored, drop.Id, 0); Game.Update(restored, 0, 1)
    equal(Game.View(restored).TotalHits, 1); equal(Game.View(restored).PendingRewardCount, 1)
    assert(Game.Drop(restored, 1, 0)); commit(restored); events(restored, "Started")
    Game.Update(restored, 0, 1); equal(#events(restored, "Awarded"), 1)
    saved = commit(restored)
    equal(saved.TotalHits, 1); equal(saved.SettledCount, 1); equal(saved.RewardState.points.Data.Balance, 100)
    Game.Update(restored, 0, 1); equal(#events(restored, "Awarded"), 0)
end)

test("removing an already landed basket archives its hit without recounting", function()
    local cfg = config({{Type = "balls", Amount = 10}})
    local session = Session.New(cfg, 0, nil, rewardRegistry)
    local drop = assert(Session.Drop(session, 1, 0))[1]
    assert(Session.Land(session, drop.Id, 0))
    cfg.Baskets[1].Id = "replacement"
    local game = Game.New(cfg, 0, Session.Snapshot(session), rewardRegistry)
    commit(game); equal(#events(game, "Started"), 0)
    Game.Update(game, 0, 1)
    equal(Game.View(game).TotalHits, 1); equal(Game.View(game).ArchivedHits, 1)
    assert(Game.Drop(game, 1, 0)); commit(game); Game.Update(game, 0, 1)
    equal(Game.View(game).TotalHits, 1); equal(Game.View(game).SettledCount, 1)
end)

test("background payouts coalesce across frames while commands and final payout save immediately", function()
    local game = Game.New(config(), 0, nil, rewardRegistry)
    assert(Game.NeedsCheckpoint(game)); commit(game)
    assert(Game.Drop(game, 3, 0)); assert(Game.NeedsCheckpoint(game)); commit(game)
    local started = events(game, "Started")
    Game.Land(game, started[1].Drop.Id, 0)
    equal(Game.NeedsCheckpoint(game), false)
    Game.Update(game, 0, 0.125); equal(Game.NeedsCheckpoint(game), false)
    Game.Land(game, started[2].Drop.Id, 0)
    Game.Update(game, 0, 0.125); assert(Game.NeedsCheckpoint(game))
    equal(commit(game).TotalHits, 2)
    Game.Land(game, started[3].Drop.Id, 0); assert(Game.NeedsCheckpoint(game))
    equal(commit(game).TotalHits, 3)
    Game.Grant(game, 0); assert(Game.NeedsCheckpoint(game)); commit(game)
    Game.RequestCheckpoint(game, 0); assert(Game.NeedsCheckpoint(game))
end)

local failures = 0
for index, case in ipairs(cases) do
    local ok, err = pcall(case.Run)
    if not ok then failures = failures + 1 end
    io.write(ok and "PASS " or "FAIL ", case.Name, ok and "\n" or ": " .. tostring(err) .. "\n")
end
io.write(#cases - failures, "/", #cases, " application specifications passed\n")
assert(failures == 0, tostring(failures) .. " application specifications failed")
