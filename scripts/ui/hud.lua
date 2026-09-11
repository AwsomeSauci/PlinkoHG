local Theme = require "scripts.ui.theme"
local Widgets = require "scripts.ui.widgets"
local Strings = require "scripts.ui.strings"
local ColonyArt = require "scripts.ui.colony_art"
local RewardText = require "scripts.ui.reward_text"
local Hud = {}

local function status(hud, message, color)
    if hud.statusText ~= message then
        gui.set_text(hud.Status, message)
        Widgets.FitText(hud.Status, 16, 24, 610)
        hud.statusText = message
    end
    if hud.statusColor ~= color then
        gui.set_color(hud.Status, Theme.Color(color))
        hud.statusColor = color
    end
end

function Hud.New(parent, config, text, rewardText)
    local hud = {
        Buttons = {}, Config = config, Text = text, ToastTime = 0, StatsOpen = false,
        NativeDebug = sys.get_engine_info().is_debug, StatCells = {}, RewardText = rewardText,
    }
    -- Labels always use the game's font and language. The engine debug font
    -- is ASCII-only, so only numeric table cells use draw_debug_text.
    local root = Widgets.Group(parent)
    Widgets.Circle(root, 75, 1031, 26, Theme.Leaf)
    ColonyArt.Ant(root, 75, 1027, 1.05, -26, Theme.Ink)
    Widgets.Text(root, 117, 1038, "PLINKO LAB", 30, Theme.Text, gui.PIVOT_W, "heading")
    Widgets.Text(root, 119, 1016, "IDDLEX", 12, Theme.Gold, gui.PIVOT_W)
    hud.Buttons.Stats = Widgets.Button(root, 584, 1030, 164, 40, text("Stats"), Theme.Panel, Theme.Muted)
    gui.set_scale(hud.Buttons.Stats.Text, vmath.vector3(0.55, 0.55, 1))

    Widgets.RoundRect(root, 191, 949, 286, 105, 19, Theme.Panel)
    Widgets.Text(root, 70, 977, text("Score"), 12, Theme.Muted, gui.PIVOT_W)
    hud.Score = Widgets.Text(root, 70, 936, "0", 34, Theme.Gold, gui.PIVOT_W, "heading")
    Widgets.RoundRect(root, 524, 949, 296, 105, 19, Theme.Panel)
    Widgets.Text(root, 398, 977, text("Balls"), 12, Theme.Muted, gui.PIVOT_W)
    hud.Balls = Widgets.Text(root, 398, 939, "", 32, Theme.Text, gui.PIVOT_W, "heading")
    hud.Refill = Widgets.Text(root, 650, 940, "", 12, Theme.Leaf, gui.PIVOT_E)
    Widgets.Box(root, 524, 911, 250, 3, Theme.Border)
    hud.Progress = Widgets.Box(root, 399, 911, 250, 3, Theme.Leaf)
    gui.set_pivot(hud.Progress, gui.PIVOT_W)

    hud.Buttons.Drop = Widgets.Button(root, 227, 203, 358, 76, text("Drop"), Theme.Leaf, Theme.Ink, text("DropHint"))
    hud.Buttons.Batch = Widgets.Button(root, 550, 203, 242, 76, text("Batch", config.BatchSize), Theme.Panel, Theme.Text, text("BatchHint"))
    hud.Status = Widgets.Text(root, 360, 144, text("Ready"), 16, Theme.Muted)
    hud.Buttons.Grant = Widgets.Button(root, 135, 87, 174, 43, text("Grant", config.GrantSize), Theme.Panel, Theme.Leaf)
    gui.set_scale(hud.Buttons.Grant.Text, vmath.vector3(0.59, 0.59, 1))
    Widgets.Text(root, 135, 53, text("GrantHint"), 11, Theme.Muted)
    hud.Buttons.Sound = Widgets.Button(root, 591, 87, 160, 43, text("SoundOn"), Theme.Panel, Theme.Muted)
    gui.set_scale(hud.Buttons.Sound.Text, vmath.vector3(0.54, 0.54, 1))
    Widgets.Text(root, 360, 22, text("Footer"), 10, Theme.Muted)
    Widgets.Text(root, 365, 87, text("RefillRule", config.RefillSeconds, config.RefillCap), 10, Theme.Muted)

    local overlay = Widgets.Group(parent)
    Widgets.RoundRect(overlay, 360, 573, 650, 620, 28, Theme.Overlay)
    Widgets.Text(overlay, 70, 843, text("StatsTitle"), 23, Theme.Text, gui.PIVOT_W)
    Widgets.Text(overlay, 70, 811, text("StatsHint"), 12, Theme.Muted, gui.PIVOT_W)
    Widgets.Box(overlay, 360, 785, 580, 1, Theme.Border)
    hud.Buttons.Close = Widgets.Button(overlay, 572, 301, 158, 36, text("StatsClose"), Theme.Border, Theme.Text)
    gui.set_scale(hud.Buttons.Close.Text, vmath.vector3(0.58, 0.58, 1))
    hud.EmptyStats = Widgets.Text(overlay, 360, 343, text("StatsEmpty"), 12, Theme.Muted)
    hud.RewardInventory = Widgets.Text(overlay, 74, 340, "", 12, Theme.Leaf, gui.PIVOT_W)
    hud.Archive = Widgets.Text(overlay, 74, 319, "", 11, Theme.Muted, gui.PIVOT_W)
    hud.Overlay = overlay
    hud.StatRoot = Widgets.Group(overlay)
    gui.set_enabled(overlay, false)
    return hud
end

function Hud.Toast(hud, message, color)
    status(hud, message, color or Theme.Leaf)
    hud.ToastTime = 3.5
end

function Hud.Update(hud, view, dt)
    local config = hud.Config
    if hud.LastScore ~= view.Score then
        gui.set_text(hud.Score, Strings.Number(view.Score))
        Widgets.FitText(hud.Score, 34, 40, 238)
        hud.LastScore = view.Score
    end
    if hud.LastBalls ~= view.Balls then
        gui.set_text(hud.Balls, Strings.Number(view.Balls))
        Widgets.FitText(hud.Balls, 32, 40, 110)
        hud.LastBalls = view.Balls
    end
    local remaining = math.max(0, math.ceil(view.RefillRemaining or 0))
    local timerText = view.Balls >= config.RefillCap and hud.Text("Full")
        or hud.Text("Refill", math.floor(remaining / 60), remaining % 60)
    if hud.LastTimer ~= timerText then
        gui.set_text(hud.Refill, timerText)
        hud.LastTimer = timerText
    end
    gui.set_size(hud.Progress, vmath.vector3(250 * math.max(0.001, view.RefillProgress or 1), 3, 0))
    Widgets.Enable(hud.Buttons.Drop, not view.SavingBlocked and not view.ServiceBusy and view.Balls >= 1)
    Widgets.Enable(hud.Buttons.Batch, not view.SavingBlocked and not view.ServiceBusy and view.Balls >= config.BatchSize)
    Widgets.Enable(hud.Buttons.Grant, not view.SavingBlocked and not view.ServiceBusy and view.Balls < config.MaxInventory)
    hud.ToastTime = math.max(0, hud.ToastTime - dt)
    if view.ServiceFailed then
        status(hud, hud.Text("ServiceUnavailable"), Theme.Gold)
        hud.ToastTime = 0
    elseif view.SavingBlocked then
        status(hud, hud.Text("SaveError"), Theme.Gold)
        hud.ToastTime = 0
    elseif view.ServiceBusy then
        status(hud, hud.Text("ServiceBusy"), Theme.Gold)
        hud.ToastTime = 0
    elseif view.RewardBlocked then
        status(hud, hud.Text("RewardPending"), Theme.Gold)
        hud.ToastTime = 0
    elseif hud.ToastTime == 0 then
        local message = view.ActiveCount > 0 and hud.Text("Flying", view.ActiveCount) or hud.Text("Ready")
        status(hud, message, Theme.Muted)
    end
    gui.set_enabled(hud.EmptyStats, view.TotalHits == 0)
end

function Hud.ToggleStats(hud, enabled)
    if enabled == nil then enabled = not hud.StatsOpen end
    hud.StatsOpen = enabled
    gui.set_enabled(hud.Overlay, hud.StatsOpen)
end

function Hud.Pick(hud, x, y)
    for buttonIndex, name in ipairs({"Close", "Stats", "Drop", "Batch", "Grant", "Sound"}) do
        local button = hud.Buttons[name]
        local visible = name ~= "Close" or hud.StatsOpen
        if visible and button.Enabled and gui.pick_node(button.Hit, x, y) then return name, button end
    end
end

function Hud.DrawDebug(hud, view)
    if not hud.StatsOpen then return end
    local cellIndex = 0
    local function draw(x, y, value, numeric, maxWidth)
        -- The assignment calls this render:draw_text; it is a render-socket message,
        -- not a Lua render.draw_text() function. It renders above GUI via debug_text.
        cellIndex = cellIndex + 1
        local node = hud.StatCells[cellIndex]
        if not node then
            node = Widgets.Text(hud.StatRoot, x, y + 5, "", 13, Theme.Text, gui.PIVOT_W)
            hud.StatCells[cellIndex] = node
        end
        if gui.get_text(node) ~= value then
            gui.set_text(node, value)
            if maxWidth then Widgets.FitText(node, 13, 24, maxWidth) end
        end
        local native = hud.NativeDebug and numeric == true
        gui.set_enabled(node, not native)
        if native then
            msg.post("@render:", "draw_debug_text", {
                text = value, position = vmath.vector3(x, y, 0), color = Theme.Color(Theme.Text),
            })
        end
    end
    draw(74, 758, hud.Text("DebugScore") .. " " .. string.format("%.0f", view.Score))
    draw(338, 758, hud.Text("DebugHits") .. " " .. string.format("%.0f", view.TotalHits))
    draw(74, 735, hud.Text("DebugActive") .. " " .. view.ActiveCount)
    draw(338, 735, hud.Text("DebugSettled") .. " " .. string.format("%.0f", view.SettledCount))
    draw(74, 704, hud.Text("DebugBasket"))
    draw(306, 704, hud.Text("DebugHits"))
    draw(468, 704, hud.Text("DebugActual"))
    draw(564, 704, hud.Text("DebugWeight"))
    for index, hit in ipairs(view.Hits) do
        local y = 676 - (index - 1) * 21
        local label = string.format("%02d / ", index) .. RewardText.Format(hud.RewardText, hit.Rewards, "table")
        draw(74, y, label, label:match("^[%d /]+$") ~= nil, 214)
        draw(306, y, string.format("%.0f", hit.Count), true)
        draw(468, y, string.format("%.2f%%", hit.Percent), true)
        draw(564, y, string.format("%.2f%%", hit.WeightPercent), true)
    end
    local inventory = view.RewardState and RewardText.Balances(hud.RewardText, view.RewardState) or ""
    if gui.get_text(hud.RewardInventory) ~= inventory then
        gui.set_text(hud.RewardInventory, inventory)
        Widgets.FitText(hud.RewardInventory, 12, 24, 565)
    end
    gui.set_enabled(hud.RewardInventory, inventory ~= "")
    gui.set_enabled(hud.EmptyStats, view.TotalHits == 0 and inventory == "")
    local archived = hud.Text("DebugArchive", view.ArchivedHits)
    if gui.get_text(hud.Archive) ~= archived then
        gui.set_text(hud.Archive, archived)
        Widgets.FitText(hud.Archive, 11, 24, 390)
    end
    gui.set_enabled(hud.Archive, view.ArchivedHits > 0)
end

function Hud.Error(parent, title, help, detail)
    Widgets.RoundRect(parent, 360, 570, 630, 290, 24, Theme.Panel)
    Widgets.Text(parent, 360, 663, title, 30, Theme.Gold, nil, "heading")
    Widgets.Text(parent, 360, 603, help, 15, Theme.Text)
    local node = Widgets.Text(parent, 360, 525, tostring(detail), 16, Theme.Muted)
    gui.set_size(node, vmath.vector3(800, 140, 0))
    gui.set_line_break(node, true)
end

function Hud.Fatal(parent, text, detail)
    Hud.Error(parent, text("ConfigError"), text("ConfigHelp"), detail)
end

return Hud
