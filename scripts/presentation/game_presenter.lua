local GameService = require "scripts.contracts.game_service"
local Ports = require "scripts.contracts.ports"
local Presenter = {}

-- Passive View MVP. No domain, storage, system clock or Defold dependencies.
-- Service results arrive as messages; Execute returning never means success.
function Presenter.New(service, view, simulation)
    return {service = GameService.Require(service), view = Ports.Require("GameView", view),
        simulation = Ports.Require("FlightSimulation", simulation), flights = {}, byId = {},
        focused = true, muted = false, statsOpen = false, elapsed = 0, lastPeg = -1, lastLand = -1}
end

local function play(presenter, name, gain, speed)
    if presenter.focused and not presenter.muted then presenter.view:PlaySound(name, gain, speed or 1) end
end

local function award(presenter, drop)
    presenter.view:Award(drop)
    if presenter.elapsed - presenter.lastLand > 0.08 then
        play(presenter, "land", 0.22)
        presenter.lastLand = presenter.elapsed
    end
end

local function drain(presenter)
    for index, event in ipairs(presenter.service:DrainEvents()) do
        if event.Kind == "Ready" then
            assert(not presenter.config, "A service must publish Ready once per instance")
            presenter.config = event.Config
            presenter.simulation:Configure(#event.Config.Baskets)
            presenter.view:Configure(event.Config, presenter.service:GetState(true).Model)
        elseif event.Kind == "Started" then
            assert(presenter.config, "Ready must precede Started")
            local drop = event.Drop
            if not presenter.byId[drop.Id] then
                local flight = presenter.simulation:Create(drop)
                local item = {flight = flight}
                presenter.flights[#presenter.flights + 1] = item
                presenter.byId[drop.Id] = item
                presenter.view:AddBall(flight)
            end
        elseif event.Kind == "Awarded" then
            local item = presenter.byId[event.Drop.Id]
            -- Authority may settle before flight ends; only its effect waits.
            if item then item.award = event.Drop else award(presenter, event.Drop) end
        elseif event.Kind == "CommandStatus" then
            if event.Status == "Rejected" then
                local code = event.Code == "save_failed" and "SaveError"
                    or event.Code == "insufficient_balls" and "Empty"
                    or event.Code == "busy" and "ServiceBusy"
                    or (event.Code == "session_limit" or event.Code == "invalid_count") and "Limit"
                    or "ServiceUnavailable"
                presenter.view:Notify(code)
            elseif event.Status == "Succeeded" then
                if event.Command == "Drop" then play(presenter, "launch", 0.25)
                elseif event.Command == "Grant" then presenter.view:Notify("Granted", event.Amount) end
            end
        elseif event.Kind == "Notice" then
            presenter.view:Notify(event.Code, event.Amount, event.Detail)
        elseif event.Kind == "SaveFailed" then presenter.view:Notify("SaveError", nil, event.Detail)
        elseif event.Kind == "RewardFailed" then presenter.view:Notify("RewardPending", nil, event.Detail)
        end
    end
end

local function render(presenter, dt)
    local state = presenter.service:GetState(presenter.statsOpen)
    if state.Phase == "failed" and not presenter.failed then
        presenter.failed = true
        presenter.view:Notify("ServiceUnavailable", nil, state.Error)
    end
    presenter.view:Render(state, dt)
end

function Presenter.Start(presenter)
    if presenter.disposed or presenter.started then return end
    presenter.started = true
    presenter.service:Open()
    drain(presenter)
    render(presenter, 0)
end

function Presenter.Update(presenter, dt)
    if presenter.disposed or not presenter.started then return end
    presenter.elapsed = presenter.elapsed + dt
    if presenter.focused then
        for index = #presenter.flights, 1, -1 do
            local item = presenter.flights[index]
            local flight = item.flight
            local contacts = presenter.simulation:Update(flight, dt)
            presenter.view:MoveBall(flight, dt)
            if contacts then
                for contactIndex, peg in ipairs(contacts) do presenter.view:Contact(peg) end
                if presenter.elapsed - presenter.lastPeg > 0.055 then
                    play(presenter, "peg", 0.14, 0.95 + flight.BasketIndex * 0.025)
                    presenter.lastPeg = presenter.elapsed
                end
            end
            if flight.Done then
                presenter.view:RemoveBall(flight.Id)
                presenter.byId[flight.Id] = nil
                presenter.flights[index] = presenter.flights[#presenter.flights]
                presenter.flights[#presenter.flights] = nil
                presenter.service:Landed(flight.Id)
                if item.award then award(presenter, item.award) end
            end
        end
    end
    presenter.service:Update(dt)
    drain(presenter)
    render(presenter, dt)
end

function Presenter.Activate(presenter, intent)
    if presenter.disposed or not presenter.config then return false end
    if intent == "Stats" or intent == "Close" then
        presenter.statsOpen = intent == "Stats" and not presenter.statsOpen
        presenter.view:SetStats(presenter.statsOpen)
    elseif intent == "Sound" then
        presenter.muted = not presenter.muted
        presenter.view:SetMuted(presenter.muted)
    elseif intent == "Drop" or intent == "Batch" or intent == "Grant" then
        local state = presenter.service:GetState(false)
        if state.Phase ~= "ready" or state.Busy then return false end
        local command = {Kind = intent == "Grant" and "Grant" or "Drop"}
        if command.Kind == "Drop" then command.Count = intent == "Batch" and presenter.config.BatchSize or 1 end
        presenter.service:Execute(command)
    else return false end
    drain(presenter)
    render(presenter, 0)
    return true
end

function Presenter.SetFocus(presenter, focused)
    if presenter.disposed or presenter.focused == focused then return end
    presenter.focused = focused
    presenter.view:CancelInput()
    if focused then presenter.service:Resume() else presenter.service:Suspend() end
    drain(presenter)
    render(presenter, 0)
end

function Presenter.Flush(presenter, completed)
    assert(type(completed) == "function", "Flush requires a completion callback")
    if presenter.disposed then completed(false, "Presenter disposed"); return end
    presenter.service:Flush(completed)
end

function Presenter.Dispose(presenter)
    if presenter.disposed then return end
    presenter.disposed = true
    local errors = {}
    local function release(label, method, owner, ...)
        local ok, err = pcall(method, owner, ...)
        if not ok then errors[#errors + 1] = label .. ": " .. tostring(err) end
    end
    release("Cancel input", presenter.view.CancelInput, presenter.view)
    release("Dispose service", presenter.service.Dispose, presenter.service)
    for index, item in ipairs(presenter.flights) do
        release("Remove ball " .. tostring(item.flight.Id), presenter.view.RemoveBall, presenter.view, item.flight.Id)
    end
    presenter.flights, presenter.byId = {}, {}
    release("Dispose view", presenter.view.Dispose, presenter.view)
    -- Report failures only after every independently owned resource was released.
    if #errors > 0 then error(table.concat(errors, "\n"), 0) end
end

return Presenter
