-- Composition of reward behavior and presentation. To extend rewards, add a
-- handler and a view, then register them here. Session/Flight/Hud stay unchanged.
local Views = require "scripts.ui.reward_views"
return {
    {Type = "points", Handler = require "scripts.domain.rewards.points", View = Views.Points},
    {Type = "balls", Handler = require "scripts.domain.rewards.balls", View = Views.Balls},
    {Type = "item", Handler = require "scripts.domain.rewards.item", View = Views.Item},
}
