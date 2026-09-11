local Game = require "scripts.application.game"
local Persistence = require "scripts.application.session_persistence"
local Data = require "scripts.domain.rewards.data"
local Ports = require "scripts.contracts.ports"
local LocalGameService = {}

-- Local economy stays local regardless of repository latency or storage medium.
function LocalGameService.New(config, registry, repository, clock, persistenceOptions)
    Ports.Require("Clock", clock)
    local persistence = Persistence.New(repository, persistenceOptions)
    local phase, game, failure = "new", nil, nil
    local events, flushes = {}, {}
    local nextCommandId, pendingCommand, pumping, disposing = 1, nil, false, false
    local service = {}
    config = Data.Copy(config)

    local function emit(event) events[#events + 1] = event end
    local function commandStatus(command, status, code)
        emit({Kind = "CommandStatus", Id = command.Id, Command = command.Kind,
            Status = status, Code = code, Amount = command.Amount})
    end
    local function collect()
        for index, event in ipairs(Game.DrainEvents(game)) do emit(event) end
    end
    local function finishFlushes(errorMessage)
        local waiting, completed = {}, {}
        for index, flush in ipairs(flushes) do
            if errorMessage or Game.GetConfirmed(game) >= flush.Generation then completed[#completed + 1] = flush
            else waiting[#waiting + 1] = flush end
        end
        flushes = waiting
        local callbackError
        for index, flush in ipairs(completed) do
            local ok, err = pcall(flush.Completed, errorMessage == nil, errorMessage)
            if not ok then callbackError = callbackError or err end
        end
        if callbackError then error(callbackError, 0) end
    end
    local function loaded(event)
        local snapshot = event.Snapshot
        local created, result = pcall(function() return Game.New(config, clock:Now(), snapshot, registry) end)
        if not created then phase, failure = "failed", tostring(result); return end
        local previousBalls = snapshot and snapshot.RewardState.balls.Data.Balance or config.InitialBalls
        game, phase = result, "ready"
        emit({Kind = "Ready", Config = Data.Copy(config)})
        local initial = Game.View(game)
        if event.Warning then emit({Kind = "Notice", Code = "SaveRecovered", Detail = event.Warning})
        elseif initial.Balls > previousBalls then emit({Kind = "Notice", Code = "Offline", Amount = initial.Balls - previousBalls})
        elseif snapshot then emit({Kind = "Notice", Code = "Restored"}) end
    end

    local function pump(dt)
        if pumping or phase == "disposed" then return end
        pumping = true
        local ok, err = pcall(function()
            -- Immediate adapters can finish loading and the initial checkpoint in
            -- this call. Bounded pumping also tolerates callbacks re-entering Flush.
            for step = 1, 16 do
                local pendingResults = Persistence.Poll(persistence, dt); dt = 0
                local results = Persistence.DrainEvents(persistence)
                for index, event in ipairs(results) do
                    if event.Kind == "Loaded" then loaded(event)
                    elseif event.Kind == "Saved" and phase == "ready" then
                        Game.Confirm(game, event.Checkpoint)
                        if pendingCommand and Game.GetConfirmed(game) >= pendingCommand.Generation then
                            commandStatus(pendingCommand, "Succeeded"); pendingCommand = nil
                        end
                        collect()
                    elseif event.Kind == "Retrying" and event.Operation == "Save" then
                        emit({Kind = "SaveFailed", Detail = event.Detail})
                    elseif event.Kind == "Failed" then phase, failure = "failed", event.Detail end
                end
                if phase == "failed" then finishFlushes(failure); break end
                if phase == "ready" then finishFlushes() end
                local state = Persistence.GetState(persistence)
                local started = phase == "ready" and not state.Busy and Game.NeedsCheckpoint(game)
                if started then Persistence.Save(persistence, Game.Checkpoint(game, clock:Now())) end
                if not started and not pendingResults and #results == 0 then break end
            end
        end)
        pumping = false
        if not ok then error(err, 0) end
    end

    function service:Open()
        if phase ~= "new" then return end
        phase = "opening"
        Persistence.Load(persistence)
        pump(0)
    end

    function service:Execute(command)
        if phase ~= "ready" or disposing then return end
        assert(type(command) == "table", "Command must be a table")
        assert(nextCommandId <= Data.MaxInteger, "Command ID range exhausted")
        local request = {Id = nextCommandId, Kind = command.Kind}
        nextCommandId = nextCommandId + 1
        local state = Persistence.GetState(persistence)
        local accepted, err
        if pendingCommand or state.Busy then accepted, err = false, "busy"
        elseif command.Kind == "Drop" then accepted, err = Game.Drop(game, command.Count, clock:Now())
        elseif command.Kind == "Grant" then request.Amount = Game.Grant(game, clock:Now()); accepted = true
        else accepted, err = false, "invalid_command" end
        if not accepted then commandStatus(request, "Rejected", err)
        else
            request.Generation = Game.GetGeneration(game)
            pendingCommand = request
            pump(0)
            if pendingCommand == request then commandStatus(request, "Pending", "save_pending") end
        end
        return request.Id
    end

    function service:Landed(id)
        if phase ~= "ready" then return end
        Game.Land(game, id, clock:Now()); collect()
    end

    function service:Update(dt)
        if phase == "disposed" or phase == "new" then return end
        if phase == "ready" then Game.Update(game, clock:Now(), dt); collect() end
        pump(dt)
    end

    function service:GetState(includeDetails)
        local storage = Persistence.GetState(persistence)
        local model = game and phase == "ready" and Game.View(game, includeDetails) or nil
        if model then model.SavingBlocked = storage.Error ~= nil; model.SavingPending = storage.Busy end
        return {Phase = phase, Busy = storage.Busy or pendingCommand ~= nil,
            Error = failure or storage.Error, Model = model}
    end

    function service:DrainEvents()
        local drained = events; events = {}; return drained
    end

    function service:Flush(completed)
        assert(type(completed) == "function", "Flush requires a completion callback")
        if phase ~= "ready" or disposing then completed(false, failure or "Service is not ready"); return end
        Game.RequestCheckpoint(game, clock:Now())
        flushes[#flushes + 1] = {Generation = Game.GetGeneration(game), Completed = completed}
        Persistence.Retry(persistence)
        pump(0)
    end

    function service:Suspend()
        if phase ~= "ready" then return end
        Game.RequestCheckpoint(game, clock:Now())
        Persistence.Retry(persistence); pump(0)
    end

    function service:Resume()
        if phase ~= "ready" then return end
        local amount = Game.Resume(game, clock:Now())
        if amount > 0 then emit({Kind = "Notice", Code = "Offline", Amount = amount}) end
        self:Suspend()
    end

    function service:Dispose()
        if phase == "disposed" or disposing then return end
        disposing = true
        local saved, saveError = pcall(function()
            if phase == "ready" and (Game.NeedsCheckpoint(game) or Game.GetGeneration(game) > Game.GetConfirmed(game)) then
                Game.RequestCheckpoint(game, clock:Now())
                Persistence.Retry(persistence); pump(0)
            end
        end) -- best effort; host awaits Flush before graceful shutdown
        phase, pendingCommand, events = "disposed", nil, {}
        local disposed, disposeError = pcall(Persistence.Dispose, persistence)
        local notified, callbackError = pcall(finishFlushes, "Service disposed before flush confirmation")
        game = nil
        if not saved then error(saveError, 0) end
        if not disposed then error(disposeError, 0) end
        if not notified then error(callbackError, 0) end
    end

    return service
end

return LocalGameService
