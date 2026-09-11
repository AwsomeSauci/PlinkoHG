local Theme = {}

function Theme.Color(hex, alpha)
    hex = hex:gsub("#", "")
    return vmath.vector4(tonumber(hex:sub(1, 2), 16) / 255,
        tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255, alpha or 1)
end

-- Woodland greens, cut earth and warm grain. Render and GUI share this palette.
Theme.Background = "171C16"
Theme.Panel = "262E22"
Theme.Board = "30271E"
Theme.Border = "4D4B35"
Theme.Text = "F4EBD5"
Theme.Muted = "ADAF91"
Theme.Leaf = "BED18A"
Theme.Gold = "EDC575"
Theme.Ink = "252A19"
Theme.Shadow = "11150F"
Theme.Disabled = "333A2D"
Theme.DisabledText = "91977E"
Theme.Overlay = "293023"
Theme.Soil = "443426"
Theme.Tunnel = "251F18"
Theme.Root = "67503A"
Theme.Stone = "A49170"
Theme.StoneLight = "DDD0AB"
Theme.Amber = "CF914B"
Theme.Highlight = "F7D88B"
Theme.Ant = "CDA576"

return Theme
