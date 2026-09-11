local Theme = require "scripts.ui.theme"
local Widgets = require "scripts.ui.widgets"
local ColonyArt = {}

local function ellipse(parent, x, y, width, height, color, rotation, alpha)
    local node = Widgets.Circle(parent, x, y, 1, color, alpha)
    gui.set_size(node, vmath.vector3(width, height, 0))
    if rotation then gui.set_euler(node, vmath.vector3(0, 0, rotation)) end
    return node
end

local function stroke(parent, x1, y1, x2, y2, width, color, alpha)
    local dx, dy = x2 - x1, y2 - y1
    local node = Widgets.Box(parent, (x1 + x2) / 2, (y1 + y2) / 2,
        math.sqrt(dx * dx + dy * dy), width, color, alpha)
    gui.set_euler(node, vmath.vector3(0, 0, math.atan2(dy, dx) * 180 / math.pi))
    return node
end

local function branch(parent, points, width, color, alpha)
    for index = 2, #points do
        local a, b = points[index - 1], points[index]
        stroke(parent, a[1], a[2], b[1], b[2], width, color, alpha)
    end
    if width > 3 then
        for index, point in ipairs(points) do
            Widgets.Circle(parent, point[1], point[2], width / 2, color, alpha)
        end
    end
end

-- The same six-legged silhouette identifies the author and inhabits the board.
-- All parts and animations belong to the caller's GUI tree; no global timers.
function ColonyArt.Ant(parent, x, y, scale, rotation, color, walking)
    local root = Widgets.Group(parent, x, y)
    gui.set_scale(root, vmath.vector3(scale, scale, 1))
    gui.set_euler(root, vmath.vector3(0, 0, rotation))
    for side = -1, 1, 2 do
        for pair = 1, 3 do
            local hip = 8 - pair * 3
            local knee = hip + (2 - pair) * 3
            local leg = Widgets.Group(root, side * 1.5, hip)
            stroke(leg, 0, 0, side * 5.5, knee - hip, 1.1, color)
            stroke(leg, side * 5.5, knee - hip, side * 8.5, knee - hip - 4, 1.1, color)
            if walking then
                local swing = (pair % 2 == 0 and 9 or -9) * side
                gui.set_euler(leg, vmath.vector3(0, 0, swing))
                gui.animate(leg, "euler.z", -swing, gui.EASING_INOUTSINE,
                    0.22, 0, nil, gui.PLAYBACK_LOOP_PINGPONG)
            end
        end
        branch(root, {{side * 2, 13}, {side * 4, 17}, {side * 8, 18}}, 1, color)
    end
    ellipse(root, 0, -5, 9, 12, color)
    ellipse(root, 0, 1.5, 3, 4, color)
    ellipse(root, 0, 5.5, 5, 7, color)
    ellipse(root, 0, 11, 7, 6, color)
    return root
end

function ColonyArt.Leaf(parent, x, y, scale, rotation)
    local root = Widgets.Group(parent, x, y)
    gui.set_euler(root, vmath.vector3(0, 0, rotation))
    ellipse(root, 0, 0, 12 * scale, 25 * scale, Theme.Leaf)
    stroke(root, 0, -14 * scale, 0, 10 * scale, scale, Theme.Ink, 0.5)
    return root
end

function ColonyArt.Nest(parent)
    -- Low-contrast strata stay behind the playable peg triangle.
    for index = 1, 5 do
        local y = 390 + index * 72
        branch(parent, {{59, y}, {140, y + 12}, {265, y - 8}, {405, y + 5},
            {542, y - 9}, {662, y + 8}}, 1.2, Theme.Soil, 0.55)
    end
    for side = -1, 1, 2 do
        local edge = side < 0 and 73 or 647
        branch(parent, {{edge, 838}, {edge + side * 6, 760}, {edge - side * 7, 662},
            {edge + side * 4, 562}, {edge - side * 3, 442}, {edge, 345}}, 23, Theme.Tunnel)
        -- Small root systems frame the nest without obscuring the peg field.
        for index = 1, 3 do
            local y = 816 - index * 119
            branch(parent, {{edge + side * 12, y + 27}, {edge, y},
                {edge - side * 8, y - 21}}, 2, Theme.Root)
            stroke(parent, edge, y, edge - side * 13, y + 3, 1.2, Theme.Root)
        end
        for index = 1, 2 do
            local y = 457 + index * 145
            local ant = ColonyArt.Ant(parent, edge, y, 0.65, side < 0 and 0 or 180, Theme.Ant, true)
            gui.animate(ant, "position.y", y + side * 48, gui.EASING_INOUTSINE,
                4.5 + index, index * 0.6, nil, gui.PLAYBACK_LOOP_PINGPONG)
        end
    end
    -- Deterministic speckles are presentation-only and never consume gameplay RNG.
    for index = 1, 30 do
        local x = 100 + (index * 173) % 520
        local y = 370 + (index * 97) % 420
        ellipse(parent, x, y, 2 + index % 3, 1.8, Theme.Root, index * 37, 0.32)
    end
    branch(parent, {{86, 847}, {164, 852}, {257, 849}, {328, 855}}, 5, Theme.Border)
    branch(parent, {{392, 855}, {473, 849}, {557, 853}, {635, 847}}, 5, Theme.Border)
    ColonyArt.Leaf(parent, 107, 866, 0.8, 48)
    ColonyArt.Leaf(parent, 132, 864, 0.55, -25)
    ColonyArt.Leaf(parent, 613, 866, 0.8, -48)
    local forager = ColonyArt.Ant(parent, 543, 858, 0.65, -90, Theme.Ant, true)
    gui.animate(forager, "position.x", 580, gui.EASING_INOUTSINE, 5, 0, nil, gui.PLAYBACK_LOOP_PINGPONG)
    ColonyArt.Leaf(forager, 0, 22, 0.65, 24)
end

return ColonyArt
