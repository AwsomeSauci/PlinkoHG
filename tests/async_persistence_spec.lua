local Data = require "scripts.domain.rewards.data"
local Config = require "scripts.domain.config"
local Registry = require "scripts.domain.rewards.registry"
local LocalService = require "scripts.application.local_game_service"
local Repository = require "scripts.infrastructure.session_repository"
local Session = require "scripts.domain.session"
local Plinko = require "scripts.bootstrap.plinko"
local Presenter = require "scripts.presentation.game_presenter"
local cases = {}
local function test(name, run) cases[#cases + 1] = {Name = name, Run = run} end
local function equal(a, b) assert(a == b, tostring(a) .. " ~= " .. tostring(b)) end
local function find(events, kind)
    for index, event in ipairs(events) do if event.Kind == kind then return event end end
end

-- Manually scheduled callback fixture. No server, HTTP or alternate game logic.
local function deferredRepository()
    local repo = {requests = {}, commits = 0, revision = "empty", results = {}, disposed = 0}
    function repo:Load(request, completed)
        self.requests[#self.requests + 1] = {Kind = "Load", Request = request, Completed = completed}
    end
    function repo:Save(request, completed)
        self.requests[#self.requests + 1] = {Kind = "Save", Request = request, Completed = completed}
    end
    function repo:Dispose() self.disposed = self.disposed + 1 end
    function repo:Reply(index, result) self.requests[index].Completed(result) end
    function repo:Loaded(index)
        self:Reply(index or 1, {Status = "ok", Revision = self.revision, Snapshot = Data.Copy(self.saved)})
    end
    function repo:Commit(index, lostResponse)
        local operation = self.requests[index]
        local request = operation.Request
        local result = self.results[request.Id]
        if not result then
            equal(request.ExpectedRevision, self.revision)
            self.commits = self.commits + 1
            self.saved = Data.Copy(request.Snapshot)
            self.revision = "etag-" .. self.commits
            result = {Status = "ok", Revision = self.revision}
            self.results[request.Id] = result
        end
        if not lostResponse then self:Reply(index, result) end
    end
    return repo
end

local function fixture()
    local registry = Registry.New(require "config.reward_types")
    local raw = Data.Copy(require "config.game")
    for index, basket in ipairs(raw.Baskets) do
        basket.Weight = index == 1 and 1 or 0
        basket.Rewards = {{Type = "points", Amount = 100}, {Type = "balls", Amount = 2}}
    end
    local config = assert(Config.Validate(raw, registry))
    local repo = deferredRepository()
    local clock = {value = 0, Now = function(self) return self.value end}
    local service = LocalService.New(config, registry, repo, clock, {TimeoutSeconds = 2, RetrySeconds = 1})
    return service, repo, clock, config, registry
end

local function ready(service, repo)
    service:Open(); repo:Loaded(); service:Update(0)
    repo:Commit(2); service:Update(0); service:DrainEvents()
end

test("only the repository changes: real composition and presenter tolerate deferred load and save", function()
    local unused, repo, clock, config = fixture()
    local view = {added = 0, awards = 0, Render = function(self, state) self.state = state end,
        Configure = function() end, Notify = function() end, SetStats = function() end,
        SetMuted = function() end, PlaySound = function() end, MoveBall = function() end,
        RemoveBall = function() end, Contact = function() end, CancelInput = function() end, Dispose = function() end,
        AddBall = function(self) self.added = self.added + 1 end,
        Award = function(self) self.awards = self.awards + 1 end}
    local presenter = Plinko.Create(nil, {Repository = repo, Config = config, Clock = clock, View = view})
    Presenter.Start(presenter)
    equal(view.state.Phase, "opening"); equal(#repo.requests, 1)
    equal(Presenter.Activate(presenter, "Drop"), false)
    repo:Loaded(); Presenter.Update(presenter, 0)
    equal(view.state.Phase, "ready"); equal(view.state.Busy, true)
    equal(Presenter.Activate(presenter, "Drop"), false)
    repo:Commit(2); Presenter.Update(presenter, 0)
    assert(Presenter.Activate(presenter, "Drop")); equal(view.added, 0)
    repo:Commit(3); Presenter.Update(presenter, 0); equal(view.added, 1)
    Presenter.Update(presenter, 60)
    equal(view.awards, 1); equal(view.state.Model.Score, 100); equal(repo.saved.TotalHits, 0)
    repo:Commit(4); Presenter.Update(presenter, 0)
    equal(repo.saved.TotalHits, 1); equal(repo.saved.RewardState.balls.Data.Balance, 13)
    local flushed
    Presenter.Flush(presenter, function(ok) flushed = ok end)
    equal(flushed, nil); repo:Commit(5); Presenter.Update(presenter, 0); equal(flushed, true)
    Presenter.Dispose(presenter)
    equal(#repo.requests, 5)
end)

test("failed or malformed delayed loading never creates or writes a fresh session", function()
    for index, response in ipairs({{Status = "failed", Error = "Denied"},
        {Status = "ok", Revision = "r", Snapshot = {Version = 3}}, {Status = "ok"}}) do
        local service, repo = fixture()
        service:Open(); repo:Reply(1, response); service:Update(0)
        equal(service:GetState().Phase, "failed")
        service:Update(20); service:Resume(); service:Execute({Kind = "Grant"}); service:Dispose()
        equal(#repo.requests, 1); equal(repo.commits, 0)
    end
end)

test("landings during a write survive its older acknowledgement and queue a newer snapshot", function()
    local service, repo = fixture(); ready(service, repo)
    service:Execute({Kind = "Drop", Count = 1}); repo:Commit(3); service:Update(0)
    local first = find(service:DrainEvents(), "Started").Drop
    local command = service:Execute({Kind = "Drop", Count = 1}); service:DrainEvents()
    equal(repo.requests[4].Request.Snapshot.TotalHits, 0)
    service:Landed(first.Id); equal(service:GetState().Model.Score, 100)
    repo:Commit(4); service:Update(0)
    local events = service:DrainEvents()
    equal(find(events, "CommandStatus").Id, command); equal(find(events, "CommandStatus").Status, "Succeeded")
    equal(find(events, "Started").Drop.Id, 2)
    service:Update(0.25) -- Background landing coalesces; the accepted command already succeeded.
    equal(repo.saved.TotalHits, 0); equal(#repo.requests, 5)
    equal(repo.requests[5].Request.Snapshot.TotalHits, 1)
    equal(repo.requests[5].Request.ExpectedRevision, "etag-3")
    repo:Commit(5); service:Update(0)
    equal(repo.saved.TotalHits, 1); equal(repo.saved.RewardState.points.Data.Balance, 100)
    repo:Reply(4, {Status = "failed", Error = "Stale response"}); service:Update(0)
    equal(service:GetState().Phase, "ready"); equal(#service:DrainEvents(), 0)
end)

test("lost save acknowledgement retries the identical operation without duplicate debit or write", function()
    local service, repo = fixture(); ready(service, repo)
    local id = service:Execute({Kind = "Drop", Count = 1}); service:DrainEvents()
    repo:Commit(3, true) -- storage committed, transport response was lost
    service:Update(2); equal(find(service:DrainEvents(), "Started"), nil)
    service:Update(1); equal(#repo.requests, 4)
    local first, retry = repo.requests[3].Request, repo.requests[4].Request
    equal(retry.Id, first.Id); equal(retry.ExpectedRevision, first.ExpectedRevision)
    equal(retry.Snapshot.RandomState, first.Snapshot.RandomState)
    equal(retry.Snapshot.Pending[1].Seed, first.Snapshot.Pending[1].Seed)
    repo:Commit(4); service:Update(0)
    local events = service:DrainEvents()
    equal(find(events, "CommandStatus").Id, id); equal(find(events, "CommandStatus").Status, "Succeeded")
    assert(find(events, "Started")); equal(repo.commits, 2); equal(service:GetState().Model.Balls, 11)
    repo:Commit(3); service:Update(0); equal(#service:DrainEvents(), 0)
end)

test("late success from a timed out attempt is accepted but subsequent stale failure is ignored", function()
    local service, repo = fixture(); ready(service, repo)
    service:Execute({Kind = "Grant"}); service:DrainEvents()
    service:Update(2); service:Update(1); service:DrainEvents()
    repo:Commit(3); service:Update(0)
    equal(find(service:DrainEvents(), "CommandStatus").Status, "Succeeded")
    repo:Reply(4, {Status = "conflict", Error = "Older retry"}); service:Update(0)
    equal(service:GetState().Phase, "ready"); equal(service:GetState().Model.Balls, 22)
end)

test("stale loading failures cannot cancel a newer pending attempt", function()
    local service, repo = fixture(); service:Open()
    service:Update(2); service:Update(1); equal(#repo.requests, 2)
    equal(repo.requests[1].Request.Id, repo.requests[2].Request.Id)
    repo:Reply(1, {Status = "failed", Error = "Old error"}); service:Update(0)
    equal(service:GetState().Phase, "opening")
    repo:Loaded(2); service:Update(0); equal(service:GetState().Phase, "ready")
    equal(repo.requests[3].Kind, "Save")
end)

test("revision conflict fails closed and does not launch, retry or overwrite", function()
    local service, repo = fixture(); ready(service, repo)
    service:Execute({Kind = "Drop", Count = 1}); service:DrainEvents()
    local flushed, detail
    service:Flush(function(ok, err) flushed, detail = ok, err end)
    repo:Reply(3, {Status = "conflict", Error = "Other device changed the save"}); service:Update(0)
    equal(service:GetState().Phase, "failed"); equal(flushed, false); assert(detail:find("Other device", 1, true))
    equal(find(service:DrainEvents(), "Started"), nil)
    service:Update(100); service:Resume(); service:Execute({Kind = "Grant"})
    equal(#repo.requests, 3)
end)

test("Flush waits for its own generation, then permits disposal from its callback", function()
    local service, repo, clock = fixture(); ready(service, repo)
    service:Execute({Kind = "Grant"})
    local calls = 0
    clock.value = 5
    service:Flush(function(ok) assert(ok); calls = calls + 1; service:Dispose() end)
    repo:Commit(3); service:Update(0); equal(calls, 0)
    equal(#repo.requests, 4); equal(repo.requests[4].Request.Snapshot.ClockAt, 5)
    repo:Commit(4); service:Update(0)
    equal(calls, 1); equal(service:GetState().Phase, "disposed"); equal(repo.disposed, 1)
    repo:Commit(4); service:Update(1); equal(calls, 1)
end)

test("disposal cancels pending Flush and ignores late loading and saving callbacks", function()
    for index, started in ipairs({false, true}) do
        local service, repo = fixture()
        if started then ready(service, repo); service:Execute({Kind = "Grant"}) else service:Open() end
        local calls, result = 0, nil
        if started then service:Flush(function(ok) calls = calls + 1; result = ok end) end
        local count = #repo.requests
        service:Dispose(); service:Dispose()
        if started then equal(calls, 1); equal(result, false); repo:Commit(3) else repo:Loaded() end
        service:Update(100); service:Resume(); service:Open()
        equal(service:GetState().Phase, "disposed"); equal(#service:DrainEvents(), 0)
        equal(repo.disposed, 1); equal(#repo.requests, count)
    end
end)

test("repository request mutation cannot alter live state or a subsequent retry payload", function()
    local service, repo = fixture(); ready(service, repo)
    service:Execute({Kind = "Drop", Count = 1})
    local expectedSeed = repo.requests[3].Request.Snapshot.Pending[1].Seed
    repo.requests[3].Request.Snapshot.Pending[1].Seed = 0
    repo.requests[3].Request.Snapshot.RewardState.balls.Data.Balance = 999
    local state = service:GetState(true); state.Model.RewardState.balls.Data.Balance = 456
    service:Update(2); service:Update(1)
    equal(service:GetState().Model.Balls, 11)
    equal(repo.requests[4].Request.Snapshot.Pending[1].Seed, expectedSeed)
    equal(repo.requests[4].Request.Snapshot.RewardState.balls.Data.Balance, 11)
end)

test("local repository acknowledges duplicate operations and rejects stale revision tokens", function()
    local unused, deferred, clock, config, registry = fixture()
    local files, writes = {}, 0
    local backend = {Path = function(self, app, name) return name end,
        Read = function(self, path) return {Status = files[path] and "loaded" or "missing", Value = Data.Copy(files[path])} end,
        Write = function(self, path, envelope) writes = writes + 1; files[path] = Data.Copy(envelope); return true end}
    local repo = Repository.New(config, registry, backend)
    local loaded, first, second, conflict
    repo:Load({Id = 1}, function(result) loaded = result end)
    local request = {Id = 2, Snapshot = Session.Snapshot(Session.New(config, 0, nil, registry)), ExpectedRevision = loaded.Revision}
    repo:Save(request, function(result) first = result end)
    repo:Save(request, function(result) second = result end)
    equal(writes, 1); equal(first.Status, "ok"); equal(second.Revision, first.Revision)
    request.Id = 3; repo:Save(request, function(result) conflict = result end)
    equal(conflict.Status, "conflict"); equal(writes, 1)
    repo:Dispose(); repo:Save(request, function() error("Late callback") end)
end)

test("delayed repositories keep independent game instances isolated", function()
    local a, ra = fixture(); local b, rb = fixture()
    ready(a, ra); ready(b, rb)
    a:Execute({Kind = "Grant"}); b:Execute({Kind = "Drop", Count = 5})
    rb:Commit(3); b:Update(0)
    assert(a:GetState().Busy); equal(b:GetState().Busy, false)
    equal(a:GetState().Model.Balls, 22); equal(b:GetState().Model.Balls, 7)
    ra:Commit(3); a:Update(0); equal(ra.saved.RewardState.balls.Data.Balance, 22)
end)

test("repository exceptions and invalid responses surface without retrying uncertain new operations", function()
    for index, implementation in ipairs({function() error("Broken adapter") end,
        function(self, request, done) done(nil) end}) do
        local service, repo, clock, config, registry = fixture()
        repo.Load = implementation
        service = LocalService.New(config, registry, repo, clock)
        service:Open(); equal(service:GetState().Phase, "failed")
        assert(service:GetState().Error); equal(repo.commits, 0)
    end
end)

test("a throwing Flush callback cannot wedge pumping or suppress another completion", function()
    local service, repo = fixture(); ready(service, repo)
    local other = 0
    service:Flush(function() error("Host callback bug") end)
    service:Flush(function(ok) assert(ok); other = other + 1 end)
    repo:Commit(3)
    equal(pcall(service.Update, service, 0), false)
    service:Update(0); equal(#repo.requests, 4)
    repo:Commit(4); service:Update(0); equal(other, 1)
    service:Execute({Kind = "Drop", Count = 1}); equal(#repo.requests, 5)
end)

test("Dispose releases ownership even when adapter cleanup and a host callback throw", function()
    local service, repo = fixture(); ready(service, repo)
    service:Flush(function() error("Host cleanup bug") end)
    repo.Dispose = function(self) self.disposed = self.disposed + 1; error("Adapter cleanup bug") end
    equal(pcall(service.Dispose, service), false)
    equal(service:GetState().Phase, "disposed"); equal(repo.disposed, 1)
    service:Dispose(); repo:Commit(3); service:Update(1)
    equal(#service:DrainEvents(), 0); equal(repo.disposed, 1)
end)

test("one local owner per storage namespace is released on disposal", function()
    local unused, deferred, clock, config, registry = fixture()
    local files, writes = {}, 0
    local backend = {Path = function(self, app, name) return app .. "/" .. name end,
        Read = function(self, path) return {Status = files[path] and "loaded" or "missing", Value = Data.Copy(files[path])} end,
        Write = function(self, path, data) writes = writes + 1; files[path] = Data.Copy(data); return true end}
    local a, b = Repository.New(config, registry, backend), Repository.New(config, registry, backend)
    local first, blocked, reopened
    a:Load({Id = 1}, function(result) first = result end)
    b:Load({Id = 1}, function(result) blocked = result end)
    equal(first.Status, "ok"); equal(blocked.Status, "failed"); equal(writes, 0)
    b:Dispose() -- A failed contender must not release the actual owner's claim.
    local c = Repository.New(config, registry, backend)
    c:Load({Id = 1}, function(result) equal(result.Status, "failed") end); c:Dispose()
    local wrapper = {OwnershipScope = backend, Path = backend.Path, Read = backend.Read, Write = backend.Write}
    local sameFilesystem = Repository.New(config, registry, wrapper)
    sameFilesystem:Load({Id = 1}, function(result) equal(result.Status, "failed") end)
    sameFilesystem:Dispose()
    a:Dispose(); a:Dispose()
    local d = Repository.New(config, registry, backend)
    d:Load({Id = 1}, function(result) reopened = result end)
    equal(reopened.Status, "ok"); d:Dispose()
end)

test("permanent local snapshot errors are failed rather than endlessly retried", function()
    local unused, deferred, clock, config, registry = fixture()
    local writes = 0
    local backend = {Path = function(self, app, name) return name end,
        Read = function() return {Status = "missing"} end,
        Write = function() writes = writes + 1; return true end}
    local repo = Repository.New(config, registry, backend)
    repo:Load({Id = 1}, function(result) equal(result.Status, "ok") end)
    repo:Save({Id = 2, ExpectedRevision = 0, Snapshot = {}}, function(result) equal(result.Status, "failed") end)
    equal(writes, 0); repo:Dispose()
end)

local failures = 0
for index, case in ipairs(cases) do
    local ok, err = pcall(case.Run)
    if not ok then failures = failures + 1 end
    io.write(ok and "PASS " or "FAIL ", case.Name, ok and "\n" or ": " .. tostring(err) .. "\n")
end
io.write(#cases - failures, "/", #cases, " async persistence specifications passed\n")
assert(failures == 0, tostring(failures) .. " async persistence specifications failed")
