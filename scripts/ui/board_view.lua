local Theme = require "scripts.ui.theme"
local Widgets = require "scripts.ui.widgets"
local ColonyArt = require "scripts.ui.colony_art"
local BallRenderer = require "scripts.ui.ball_renderer"
local RewardText = require "scripts.ui.reward_text"
local BoardView = {}

function BoardView.New(parent, board, config, rewardText, renderOptions)
    local view = {Pegs = {}, Baskets = {}, Board = board, Renderer = BallRenderer.New(board.BallRadius, renderOptions), RewardText = rewardText}
    local root = Widgets.Group(parent)
    Widgets.RoundRect(root, 360, 573, 650, 620, 28, Theme.Border)
    Widgets.RoundRect(root, 360, 574, 646, 616, 27, Theme.Board)
    ColonyArt.Nest(root)
    Widgets.Box(root, 360, 833, 21, 42, Theme.Tunnel)
    Widgets.Circle(root, 360, 861, 21, Theme.Root)
    Widgets.Circle(root, 360, 861, 16, Theme.Shadow)
    Widgets.Circle(root, 360, 861, 7, Theme.Gold, 0.8)

    for index, peg in ipairs(board.Pegs) do
        local halo = Widgets.Circle(root, peg.X, peg.Y, board.PegRadius * 3, Theme.Leaf, 0)
        Widgets.Circle(root, peg.X, peg.Y - 2, board.PegRadius + 1, Theme.Tunnel)
        Widgets.Circle(root, peg.X, peg.Y, board.PegRadius, Theme.Stone)
        Widgets.Circle(root, peg.X - 0.6, peg.Y + 1.5, board.PegRadius * 0.6, Theme.StoneLight)
        view.Pegs[index] = halo
    end

    for index, basket in ipairs(board.Baskets) do
        local color = config.Baskets[index].Color
        local width = basket.Width - 4
        local panel = Widgets.RoundRect(root, basket.X, basket.Y, width, 49, 9, Theme.Root)
        Widgets.RoundRect(panel, 0, 1, width - 4, 43, 7, Theme.Tunnel)
        Widgets.RoundRect(panel, 0, -12, width - 8, 13, 4, color)
        local reward = Widgets.Text(panel, 0, 8, RewardText.Format(rewardText, config.Baskets[index].Rewards, "badge"), 18, Theme.Text)
        Widgets.FitText(reward, 18, 24, width - 8)
        local glow = Widgets.Box(root, basket.X, basket.Y + 29, width - 5, 3, Theme.Gold, 0)
        local popup = Widgets.Text(root, basket.X, basket.Y + 60, "", 21, Theme.Gold)
        view.Baskets[index] = {Panel = panel, Glow = glow, Popup = popup, X = basket.X, Y = basket.Y}
    end

    return view
end

function BoardView.Acquire(view, flight)
    return BallRenderer.Acquire(view.Renderer, flight)
end

function BoardView.Move(visual, flight, dt)
    BallRenderer.Move(visual, flight, dt)
end

function BoardView.Release(visual)
    BallRenderer.Release(visual)
end

function BoardView.Flush(view, visible)
    BallRenderer.Flush(view.Renderer, visible)
end

function BoardView.Dispose(view)
    BallRenderer.Dispose(view.Renderer)
end

function BoardView.Contact(view, index)
    local node = view.Pegs[index]
    gui.cancel_animations(node, "color.w")
    gui.cancel_animations(node, "scale")
    gui.set_color(node, Theme.Color(Theme.Leaf, 0.55))
    gui.set_scale(node, vmath.vector3(0.55, 0.55, 1))
    gui.animate(node, "color.w", 0, gui.EASING_OUTQUAD, 0.4)
    gui.animate(node, "scale", vmath.vector3(1.8, 1.8, 1), gui.EASING_OUTQUAD, 0.4)
end

function BoardView.Land(view, result)
    local basket = view.Baskets[result.BasketIndex]
    if not basket then return end
    gui.cancel_animations(basket.Panel, "scale")
    gui.set_scale(basket.Panel, vmath.vector3(1.04, 1.12, 1))
    gui.animate(basket.Panel, "scale", vmath.vector3(1, 1, 1), gui.EASING_OUTBACK, 0.3)
    gui.cancel_animations(basket.Glow, "color.w")
    gui.set_color(basket.Glow, Theme.Color(Theme.Gold))
    gui.animate(basket.Glow, "color.w", 0, gui.EASING_OUTQUAD, 0.7)
    gui.cancel_animations(basket.Popup, "position")
    gui.cancel_animations(basket.Popup, "color.w")
    gui.set_text(basket.Popup, "+" .. RewardText.Format(view.RewardText, result.Rewards, "badge"))
    Widgets.FitText(basket.Popup, 21, 24, view.Board.Spacing - 3)
    gui.set_position(basket.Popup, vmath.vector3(basket.X, basket.Y + 48, 0))
    gui.set_color(basket.Popup, Theme.Color(Theme.Gold))
    gui.animate(basket.Popup, "position.y", basket.Y + 90, gui.EASING_OUTQUAD, 0.85)
    gui.animate(basket.Popup, "color.w", 0, gui.EASING_INQUAD, 0.85)
end

return BoardView
