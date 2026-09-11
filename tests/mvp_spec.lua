-- Contract and presenter specifications, no server, transport or Defold globals.
local Config = require "scripts.domain.config"
local Registry = require "scripts.domain.rewards.registry"
local Data = require "scripts.domain.rewards.data"
local LocalService = require "scripts.application.local_game_service"
local Presenter = require "scripts.presentation.game_presenter"
local Simulation = require "scripts.simulation.flight_simulator"
local Repository = require "scripts.infrastructure.session_repository"
local Ports = require "scripts.contracts.ports"
local Plinko = require "scripts.bootstrap.plinko"
local cases = {}
local function test(name, run) cases[#cases + 1] = {Name = name, Run = run} end
local function equal(a, b) assert(a == b, tostring(a) .. " ~= " .. tostring(b)) end

local function fixture()
    local registry = Registry.New(require "config.reward_types")
    local raw = Data.Copy(require "config.game")
    for index, basket in ipairs(raw.Baskets) do
        basket.Weight = index == 1 and 1 or 0
        basket.Rewards = {{Type = "points", Amount = 100}, {Type = "balls", Amount = 2}}
    end
    local config = assert(Config.Validate(raw, registry))
    local clock = {value = 0, reads = 0, Now = function(self) self.reads = self.reads + 1; return self.value end}
    local repo = {writes = 0, fail = false, revision = 0,
        Dispose = function(self) self.disposed = true end,
        Load = function(self, request, done) done({Status = "ok", Snapshot = Data.Copy(self.saved), Revision = self.revision}) end,
        Save = function(self, request, done)
            self.writes = self.writes + 1
            if self.fail then done({Status = "retry", Error = "Disk full"}); return end
            self.saved = Data.Copy(request.Snapshot); self.revision = self.revision + 1
            done({Status = "ok", Revision = self.revision})
        end,
    }
    return LocalService.New(config, registry, repo, clock), config, repo, clock, registry
end

local function recordingView()
    local view = {balls = {}, added = 0, awards = 0, notices = {}, sounds = {}, disposed = 0}
    function view:Configure(config) self.config = config end
    function view:Render(state) self.state = state end
    function view:Notify(code) self.notices[#self.notices + 1] = code end
    function view:SetStats(value) self.stats = value end
    function view:SetMuted(value) self.muted = value end
    function view:PlaySound(name) self.sounds[#self.sounds + 1] = name end
    function view:AddBall(flight) self.balls[flight.Id] = true; self.added = self.added + 1 end
    function view:MoveBall(flight) assert(self.balls[flight.Id]) end
    function view:RemoveBall(id) self.balls[id] = nil end
    function view:Contact() end
    function view:Award() self.awards = self.awards + 1 end
    function view:CancelInput() self.cancelled = true end
    function view:Dispose() self.disposed = self.disposed + 1 end
    return view
end

local function find(events, kind)
    for index, event in ipairs(events) do if event.Kind == kind then return event end end
end

test("local service drives the real presenter and flight through composite payout", function()
    local service, config, repo = fixture()
    local view = recordingView()
    local presenter = Presenter.New(service, view, Simulation.New())
    Presenter.Start(presenter)
    equal(view.state.Model.Balls, 12)
    assert(Presenter.Activate(presenter, "Drop"))
    equal(view.added, 1); equal(view.state.Model.Balls, 11)
    equal(#repo.saved.Pending, 1)
    Presenter.Update(presenter, 60)
    equal(view.awards, 1); equal(next(view.balls), nil)
    equal(view.state.Model.Score, 100); equal(view.state.Model.Balls, 13)
    equal(repo.saved.TotalHits, 1); equal(#repo.saved.Pending, 0)
    Presenter.Dispose(presenter)
end)

test("config and service projections are detached data; reading never advances time or writes", function()
    local service, config, repo, clock = fixture()
    equal(config.RewardRegistry, nil); assert(Data.Copy(config))
    service:Open()
    local event = find(service:DrainEvents(), "Ready")
    event.Config.BatchSize = 999
    local reads, writes = clock.reads, repo.writes
    clock.value = 1000
    local state = service:GetState(true)
    state.Model.Balls = 999; state.Model.RewardState.points.Data.Balance = 999
    equal(service:GetState(true).Model.Score, 0); equal(service:GetState().Model.Balls, 12)
    equal(clock.reads, reads); equal(repo.writes, writes)
    service:Update(1)
    equal(service:GetState().Model.Balls, 20)
end)

test("service loading failures never write a fresh session over unread progress", function()
    for index, load in ipairs({function(self, request, done) done({Status = "failed", Error = "Denied"}) end, function() error("Unavailable") end}) do
        local service, config, repo, clock, registry = fixture()
        repo.Load = load
        service = LocalService.New(config, registry, repo, clock)
        service:Open(); equal(service:GetState().Phase, "failed")
        service:Execute({Kind = "Drop", Count = 1}); service:Update(1); service:Dispose()
        equal(repo.writes, 0)
    end
end)

test("service delays playback until persistence recovers and retains paid outcomes", function()
    local service, config, repo = fixture()
    service:Open(); service:DrainEvents()
    repo.fail = true
    service:Execute({Kind = "Drop", Count = 1})
    local events = service:DrainEvents()
    equal(find(events, "Started"), nil)
    equal(find(events, "CommandStatus").Status, "Pending")
    equal(service:GetState().Model.Balls, 11)
    repo.fail = false; service:Update(1)
    local drop = assert(find(service:DrainEvents(), "Started")).Drop
    service:Landed(drop.Id); service:Landed(drop.Id); service:Update(0)
    equal(service:GetState().Model.Score, 100); equal(repo.saved.TotalHits, 1)
end)

test("resume and disposal belong to the service and are idempotent", function()
    local service, config, repo, clock = fixture()
    service:Open(); service:DrainEvents()
    service:Suspend(); clock.value = 61; service:Resume()
    equal(find(service:DrainEvents(), "Notice").Amount, 2)
    service:Dispose(); local writes = repo.writes
    service:Dispose(); service:Open(); service:Resume(); service:Update(1)
    service:Execute({Kind = "Grant"}); service:Landed(1)
    equal(repo.writes, writes); equal(#service:DrainEvents(), 0)
    equal(service:GetState().Phase, "disposed")
end)

-- A manually driven port fixture, not an alternate implementation or server.
-- This proves Presenter does not depend on synchronous local command results.
local function deferredPort(config)
    local service = {phase = "new", busy = false, events = {}, commands = {}, landed = {}}
    function service:Open() self.phase = "opening" end
    function service:Execute(command) self.commands[#self.commands + 1] = command; self.busy = true end
    function service:Landed(id) self.landed[#self.landed + 1] = id end
    function service:Update() end
    function service:GetState()
        return {Phase = self.phase, Busy = self.busy, Model = self.phase == "ready" and
            {Balls = 12, Score = 0, ActiveCount = 0, TotalHits = 0, ArchivedHits = 0} or nil}
    end
    function service:DrainEvents() local result = self.events; self.events = {}; return result end
    function service:Suspend() self.suspended = true end
    function service:Resume() self.suspended = false end
    function service:Flush(done) done(true) end
    function service:Dispose() self.phase = "disposed"; self.events = {} end
    return service
end

test("same presenter tolerates delayed Ready and command results without optimistic flight", function()
    local localService, config = fixture()
    local service, view = deferredPort(config), recordingView()
    local presenter = Presenter.New(service, view, Simulation.New())
    Presenter.Start(presenter)
    equal(view.state.Phase, "opening"); equal(Presenter.Activate(presenter, "Drop"), false)
    service.phase = "ready"; service.events = {{Kind = "Ready", Config = config}}
    Presenter.Update(presenter, 0)
    Presenter.Activate(presenter, "Batch")
    equal(service.commands[1].Count, config.BatchSize); equal(view.added, 0)
    equal(Presenter.Activate(presenter, "Grant"), false); equal(#service.commands, 1)
    Presenter.Update(presenter, 1); equal(view.added, 0)
    service.busy = false
    local drop = {Id = 7, BasketId = config.Baskets[1].Id, BasketIndex = 1, Seed = 15}
    service.events = {{Kind = "CommandStatus", Command = "Drop", Status = "Succeeded"}, {Kind = "Started", Drop = drop}}
    Presenter.Update(presenter, 0); equal(view.added, 1)
    Presenter.Update(presenter, 60); equal(service.landed[1], 7); equal(view.awards, 0)
    service.events = {{Kind = "Awarded", Drop = drop}}
    Presenter.Update(presenter, 0); equal(view.awards, 1)
    Presenter.Dispose(presenter)
    service.events = {{Kind = "Started", Drop = drop}}
    Presenter.Update(presenter, 1); Presenter.Activate(presenter, "Drop"); Presenter.Dispose(presenter)
    equal(view.added, 1); equal(view.disposed, 1); equal(#service.commands, 1)
end)

test("early authoritative payout waits only for its visual effect; focus pauses simulation", function()
    local localService, config = fixture()
    local service, view = deferredPort(config), recordingView()
    local presenter = Presenter.New(service, view, Simulation.New())
    Presenter.Start(presenter)
    local drop = {Id = 2, BasketId = config.Baskets[1].Id, BasketIndex = 1, Seed = 6}
    service.phase = "ready"
    service.events = {{Kind = "Ready", Config = config}, {Kind = "Started", Drop = drop}, {Kind = "Awarded", Drop = drop}}
    Presenter.Update(presenter, 0); equal(view.awards, 0)
    Presenter.SetFocus(presenter, false); Presenter.Update(presenter, 60)
    equal(view.awards, 0); assert(service.suspended)
    Presenter.SetFocus(presenter, true); Presenter.Activate(presenter, "Sound")
    Presenter.Activate(presenter, "Stats"); assert(view.stats)
    Presenter.Activate(presenter, "Close"); equal(view.stats, false)
    Presenter.Update(presenter, 60); equal(view.awards, 1); equal(#view.sounds, 0)
end)

test("async rejection displays a notice without debit or launch assumed by presenter", function()
    local localService, config = fixture()
    local service, view = deferredPort(config), recordingView()
    local presenter = Presenter.New(service, view, Simulation.New())
    Presenter.Start(presenter); service.phase = "ready"
    service.events = {{Kind = "Ready", Config = config}}; Presenter.Update(presenter, 0)
    Presenter.Activate(presenter, "Drop")
    service.busy = false
    service.events = {{Kind = "CommandStatus", Command = "Drop", Status = "Rejected", Code = "unavailable"}}
    Presenter.Update(presenter, 0)
    equal(view.notices[1], "ServiceUnavailable"); equal(view.added, 0); equal(#view.sounds, 0)
end)

test("host-provided service bypasses local configuration, clock and storage", function()
    local localService, config = fixture()
    local service, view = deferredPort(config), recordingView()
    local presenter, createdView = Plinko.Create(nil, {
        Service = service, View = view, Config = {Invalid = true},
        Clock = {}, Storage = {}, RewardTypes = {},
    })
    equal(createdView, view)
    Presenter.Start(presenter); equal(view.state.Phase, "opening")
    service.phase = "ready"; service.events = {{Kind = "Ready", Config = config}}
    Presenter.Update(presenter, 0); Presenter.Activate(presenter, "Drop")
    equal(#service.commands, 1)
    Presenter.Dispose(presenter)
end)

test("ports fail at construction when implementations are incomplete", function()
    local service = fixture()
    equal(pcall(Presenter.New, {}, recordingView(), Simulation.New()), false)
    equal(pcall(Presenter.New, service, {}, Simulation.New()), false)
    equal(pcall(Ports.Require, "Clock", {}), false)
end)

test("independent local services and storage namespaces do not share economy or files", function()
    local first, config, repo, clock, registry = fixture()
    local second = fixture()
    first:Open(); second:Open(); first:Execute({Kind = "Drop", Count = 5})
    equal(first:GetState().Model.Balls, 7); equal(second:GetState().Model.Balls, 12)
    local files = {}
    local backend = {Path = function(self, app, slot) return app .. "/" .. slot end,
        Read = function(self, path) return {Status = files[path] and "loaded" or "missing", Value = Data.Copy(files[path])} end,
        Write = function(self, path, data) files[path] = Data.Copy(data); return true end}
    local a = LocalService.New(config, registry, Repository.New(config, registry, backend, "game-a"), clock)
    local b = LocalService.New(config, registry, Repository.New(config, registry, backend, "game-b"), clock)
    a:Open(); b:Open(); a:Execute({Kind = "Drop", Count = 1})
    b:Dispose(); a:Dispose()
    local restored = LocalService.New(config, registry, Repository.New(config, registry, backend, "game-b"), clock)
    restored:Open(); equal(restored:GetState().Model.Balls, 12)
end)

test("retained commands have a correlated Pending then exactly one terminal success", function()
    for index, command in ipairs({{Kind = "Drop", Count = 1}, {Kind = "Grant"}}) do
        local service, config, repo, clock, registry = fixture()
        config.MaxInventory = 20 -- Grant is partially capped: 8, not GrantSize=10.
        service = LocalService.New(config, registry, repo, clock)
        service:Open(); service:DrainEvents(); repo.fail = true
        local id = service:Execute(command)
        local pending = assert(find(service:DrainEvents(), "CommandStatus"))
        equal(pending.Id, id); equal(pending.Status, "Pending"); assert(service:GetState().Busy)
        local balance = service:GetState().Model.Balls
        local rejectedId = service:Execute({Kind = "Grant"})
        local rejected = assert(find(service:DrainEvents(), "CommandStatus"))
        equal(rejected.Id, rejectedId); assert(rejectedId ~= id)
        equal(rejected.Status, "Rejected"); equal(rejected.Code, "busy")
        service:Update(1); equal(find(service:DrainEvents(), "CommandStatus"), nil)
        equal(service:GetState().Model.Balls, balance)
        repo.fail = false; service:Resume()
        local events = service:DrainEvents()
        local finished = assert(find(events, "CommandStatus"))
        equal(finished.Id, id); equal(finished.Status, "Succeeded"); equal(finished.Code, nil)
        equal(service:GetState().Busy, false); equal(service:GetState().Model.Balls, balance)
        if command.Kind == "Grant" then equal(finished.Amount, 8)
        else assert(find(events, "Started")) end
        service:Update(5); service:Suspend(); service:Resume()
        equal(find(service:DrainEvents(), "CommandStatus"), nil)
        equal(repo.saved.RewardState.balls.Data.Balance, balance)
    end
end)

test("presenter reports a deferred grant only after its checkpoint succeeds", function()
    local service, config, repo = fixture()
    local view = recordingView()
    local presenter = Presenter.New(service, view, Simulation.New())
    Presenter.Start(presenter); repo.fail = true
    Presenter.Activate(presenter, "Grant")
    equal(#view.notices, 1); equal(view.notices[1], "SaveError")
    equal(Presenter.Activate(presenter, "Grant"), false)
    Presenter.Update(presenter, 1); equal(#view.notices, 1)
    repo.fail = false; Presenter.Update(presenter, 1)
    equal(#view.notices, 2); equal(view.notices[2], "Granted")
    Presenter.Update(presenter, 5); equal(#view.notices, 2)
    Presenter.Dispose(presenter)
end)

test("presenter completes every cleanup stage even when service, input and visuals throw", function()
    local service, config, repo = fixture()
    local view = recordingView()
    local presenter = Presenter.New(service, view, Simulation.New())
    Presenter.Start(presenter); Presenter.Activate(presenter, "Batch")
    equal(view.added, config.BatchSize)
    local removed = 0
    repo.Dispose = function() error("Storage cleanup failed") end
    view.CancelInput = function() error("Input cleanup failed") end
    view.RemoveBall = function(self, id)
        self.balls[id] = nil; removed = removed + 1; error("Ball cleanup failed")
    end
    view.Dispose = function(self) self.disposed = self.disposed + 1; error("View cleanup failed") end
    local ok, err = pcall(Presenter.Dispose, presenter)
    equal(ok, false)
    for index, message in ipairs({"Storage cleanup failed", "Input cleanup failed", "Ball cleanup failed", "View cleanup failed"}) do
        assert(err:find(message, 1, true))
    end
    equal(removed, config.BatchSize); equal(view.disposed, 1); equal(next(view.balls), nil)
    equal(service:GetState().Phase, "disposed"); equal(#presenter.flights, 0); equal(next(presenter.byId), nil)
    Presenter.Dispose(presenter); Presenter.Update(presenter, 1)
    equal(removed, config.BatchSize); equal(view.disposed, 1)
end)

test("failed composition releases transferred service and view ownership", function()
    local service = fixture()
    local view = recordingView()
    local ok, err = pcall(Plinko.Create, nil, {Service = service, View = view, Simulation = {}})
    equal(ok, false); assert(err:find("FlightSimulation", 1, true))
    equal(service:GetState().Phase, "disposed"); equal(view.disposed, 1)
end)

test("disposing during payout coalescing persists changes before releasing storage", function()
    local service, config, repo = fixture()
    service:Open(); service:Execute({Kind = "Drop", Count = 2})
    local drop = find(service:DrainEvents(), "Started").Drop
    service:Landed(drop.Id); service:Update(0)
    equal(repo.saved.TotalHits, 0)
    service:Dispose()
    equal(repo.saved.TotalHits, 1); equal(#repo.saved.Pending, 1)
end)

local failures = 0
for index, case in ipairs(cases) do
    local ok, err = pcall(case.Run)
    if not ok then failures = failures + 1 end
    io.write(ok and "PASS " or "FAIL ", case.Name, ok and "\n" or ": " .. tostring(err) .. "\n")
end
io.write(#cases - failures, "/", #cases, " MVP specifications passed\n")
assert(failures == 0, tostring(failures) .. " MVP specifications failed")
