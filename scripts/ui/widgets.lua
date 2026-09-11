local Theme = require "scripts.ui.theme"
local Widgets = {}

local function attach(node, parent)
    gui.set_parent(node, parent, false)
    gui.set_inherit_alpha(node, true)
    return node
end

function Widgets.Group(parent, x, y)
    local node = gui.new_box_node(vmath.vector3(x or 0, y or 0, 0), vmath.vector3(1, 1, 0))
    gui.set_visible(node, false)
    return attach(node, parent)
end

function Widgets.Box(parent, x, y, width, height, color, alpha)
    local node = gui.new_box_node(vmath.vector3(x, y, 0), vmath.vector3(width, height, 0))
    gui.set_color(node, Theme.Color(color, alpha))
    return attach(node, parent)
end

function Widgets.Circle(parent, x, y, radius, color, alpha)
    local node = gui.new_pie_node(vmath.vector3(x, y, 0), vmath.vector3(radius * 2, radius * 2, 0))
    gui.set_perimeter_vertices(node, 40)
    gui.set_color(node, Theme.Color(color, alpha))
    return attach(node, parent)
end

-- Vector geometry keeps cards crisp at every scale, without a texture dependency.
function Widgets.RoundRect(parent, x, y, width, height, radius, color)
    local group = Widgets.Group(parent, x, y)
    local parts = {
        Widgets.Box(group, 0, 0, width - radius * 2, height, color),
        Widgets.Box(group, 0, 0, width, height - radius * 2, color),
    }
    for xIndex, dx in ipairs({-1, 1}) do
        for yIndex, dy in ipairs({-1, 1}) do
            parts[#parts + 1] = Widgets.Circle(group, dx * (width / 2 - radius), dy * (height / 2 - radius), radius, color)
        end
    end
    return group, parts
end

function Widgets.Text(parent, x, y, text, size, color, pivot, font)
    local node = gui.new_text_node(vmath.vector3(x, y, 0), text)
    gui.set_font(node, font or "body")
    local baseSize = font == "heading" and 40 or 24
    gui.set_scale(node, vmath.vector3(size / baseSize, size / baseSize, 1))
    gui.set_color(node, Theme.Color(color or Theme.Text))
    gui.set_pivot(node, pivot or gui.PIVOT_CENTER)
    return attach(node, parent)
end

function Widgets.Button(parent, x, y, width, height, label, fill, textColor, hint)
    local root = Widgets.Group(parent, x, y)
    local shadow = Widgets.RoundRect(root, 0, -4, width, height, 16, Theme.Shadow)
    local surface, parts = Widgets.RoundRect(root, 0, 0, width, height, 16, fill)
    local hit = Widgets.Box(root, 0, 0, width, height, "FFFFFF", 0)
    local text = Widgets.Text(root, 0, hint and 9 or 0, label, 20, textColor)
    local hintNode = hint and Widgets.Text(root, 0, -19, hint, 11, textColor) or nil
    return {
        Root = root, Surface = surface, Parts = parts, Shadow = shadow, Hit = hit,
        Text = text, Hint = hintNode, Fill = fill, TextColor = textColor, Enabled = true,
    }
end

function Widgets.FitText(node, size, baseSize, maxWidth)
    local font = gui.get_font_resource(gui.get_font(node))
    local metrics = resource.get_text_metrics(font, gui.get_text(node), {
        leading = gui.get_leading(node),
        tracking = gui.get_tracking(node),
        line_break = false,
    })
    local scale = math.min(size / baseSize, maxWidth / math.max(1, metrics.width))
    gui.set_scale(node, vmath.vector3(scale, scale, 1))
end

function Widgets.Enable(button, enabled)
    if button.Enabled == enabled then return end
    button.Enabled = enabled
    -- Keep overlapping vector parts opaque so disabled cards have no alpha seams.
    local fill = Theme.Color(enabled and button.Fill or Theme.Disabled)
    for index, node in ipairs(button.Parts) do gui.set_color(node, fill) end
    local textColor = Theme.Color(enabled and button.TextColor or Theme.DisabledText)
    gui.set_color(button.Text, textColor)
    if button.Hint then gui.set_color(button.Hint, textColor) end
end

function Widgets.Press(button, pressed)
    local scale = pressed and 0.97 or 1
    gui.cancel_animations(button.Root, "scale")
    gui.animate(button.Root, "scale", vmath.vector3(scale, scale, 1), gui.EASING_OUTQUAD, 0.1)
end

return Widgets
