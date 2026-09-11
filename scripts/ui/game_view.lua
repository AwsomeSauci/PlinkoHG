local Board = require "scripts.simulation.board"
local BoardView = require "scripts.ui.board_view"
local Hud = require "scripts.ui.hud"
local Widgets = require "scripts.ui.widgets"
local Strings = require "scripts.ui.strings"
local Theme = require "scripts.ui.theme"
local RewardText = require "scripts.ui.reward_text"
local GameView = {}

-- Passive Defold view: GUI, visual handles and pointer capture, no game service.
function GameView.New(parent, rewardTypes, renderOptions)
    local owner = msg.url()
    local root = Widgets.Group(parent, -360, -540)
    local text = Strings.New("ru")
    local hud, boardView, formatter, loading, pressedName, pressedButton, lastModel
    local visuals, disposed, failed = {}, false, false
    local view = {}

    function view:Configure(config, initialModel)
        assert(not hud and not disposed, "View is already configured or disposed")
        if loading then gui.delete_node(loading); loading = nil end
        text = Strings.New(config.Locale)
        formatter = RewardText.New(rewardTypes, text, config)
        if initialModel and initialModel.RewardState then RewardText.Balances(formatter, initialModel.RewardState) end
        boardView = BoardView.New(root, Board.New(#config.Baskets), config, formatter, renderOptions)
        hud = Hud.New(root, config, text, formatter)
    end

    function view:Render(state, dt)
        if disposed then return end
        if not hud then
            if not loading and not failed and state.Phase ~= "failed" then
                loading = Widgets.Text(root, 360, 570, text("ServiceLoading"), 24, Theme.Text)
            end
            return
        end
        lastModel = state.Model or lastModel
        if not lastModel then return end
        lastModel.ServiceBusy = state.Busy or state.Phase ~= "ready"
        lastModel.ServiceFailed = state.Phase == "failed"
        Hud.Update(hud, lastModel, dt)
        if lastModel.Hits then Hud.DrawDebug(hud, lastModel) end
        BoardView.Flush(boardView, not hud.StatsOpen)
    end

    function view:Notify(code, amount, detail)
        if detail then print("[Plinko/" .. code .. "] " .. tostring(detail)) end
        if not hud then
            if failed then return end
            failed = true
            if loading then gui.delete_node(loading); loading = nil end
            Hud.Error(root, text("ServiceUnavailable"), text("ServiceHelp"), detail or code)
        elseif code ~= "RewardPending" then
            Hud.Toast(hud, amount ~= nil and text(code, amount) or text(code),
                (code == "SaveError" or code == "ServiceUnavailable") and Theme.Gold or nil)
        end
    end

    function view:SetStats(enabled) Hud.ToggleStats(hud, enabled) end
    function view:SetMuted(muted) gui.set_text(hud.Buttons.Sound.Text, text(muted and "SoundOff" or "SoundOn")) end
    function view:PlaySound(name, gain, speed)
        sound.play(msg.url(owner.socket, owner.path, name), {gain = gain, speed = speed})
    end
    function view:AddBall(flight) visuals[flight.Id] = BoardView.Acquire(boardView, flight) end
    function view:MoveBall(flight, dt) BoardView.Move(assert(visuals[flight.Id]), flight, dt) end
    function view:RemoveBall(id)
        if visuals[id] then BoardView.Release(visuals[id]); visuals[id] = nil end
    end
    function view:Contact(peg) BoardView.Contact(boardView, peg) end
    function view:Award(drop)
        BoardView.Land(boardView, drop)
        Hud.Toast(hud, text("Award", RewardText.Format(formatter, drop.Rewards, "full")), Theme.Gold)
    end
    function view:CancelInput()
        local button = pressedButton
        pressedName, pressedButton = nil, nil
        if button then Widgets.Press(button, false) end
    end

    function view:Pointer(action)
        if disposed or not hud then return nil, false end
        if action.pressed then
            self:CancelInput()
            pressedName, pressedButton = Hud.Pick(hud, action.x, action.y)
            if pressedButton then Widgets.Press(pressedButton, true); return nil, true end
        elseif action.released then
            local name = Hud.Pick(hud, action.x, action.y)
            local previous = pressedName
            self:CancelInput()
            return previous and name == previous and name or nil, previous ~= nil
        end
        return nil, false
    end

    function view:Dispose()
        if disposed then return end
        disposed = true
        local cancelled, cancelError = pcall(self.CancelInput, self)
        local released, releaseError = true, nil
        if boardView then released, releaseError = pcall(BoardView.Dispose, boardView) end
        visuals = {}
        local deleted, deleteError = pcall(gui.delete_node, root)
        local errors = {}
        if not cancelled then errors[#errors + 1] = tostring(cancelError) end
        if not released then errors[#errors + 1] = tostring(releaseError) end
        if not deleted then errors[#errors + 1] = tostring(deleteError) end
        if #errors > 0 then error(table.concat(errors, "\n"), 0) end
    end

    return view
end

return GameView
