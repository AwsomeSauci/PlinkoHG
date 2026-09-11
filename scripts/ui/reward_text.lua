local Data = require "scripts.domain.rewards.data"
local RewardText = {}

function RewardText.New(registrations, text, config)
    local formatter = {views = {}, order = {}, text = text}
    for index, entry in ipairs(registrations) do
        assert(type(entry.View) == "table" and type(entry.View.Format) == "function", "Reward requires a view formatter")
        assert(entry.View.Balance == nil or type(entry.View.Balance) == "function", "Reward Balance must be a function")
        formatter.views[entry.Type] = entry.View
        formatter.order[#formatter.order + 1] = entry.Type
    end
    if config then
        for index, basket in ipairs(config.Baskets) do
            for modeIndex, mode in ipairs({"badge", "table", "full"}) do RewardText.Format(formatter, basket.Rewards, mode) end
        end
    end
    return formatter
end

function RewardText.Format(formatter, rewards, mode)
    if mode == "badge" and #rewards > 1 then return formatter.text("RewardBundle", #rewards) end
    local parts = {}
    for index, reward in ipairs(rewards) do
        local label = formatter.views[reward.Type].Format(Data.Copy(reward), formatter.text, mode)
        assert(type(label) == "string", "Reward formatter must return a string")
        parts[index] = label
    end
    return table.concat(parts, " + ")
end

function RewardText.Balances(formatter, state)
    local parts = {}
    for index, name in ipairs(formatter.order) do
        local view = formatter.views[name]
        if view.Balance then
            local label = view.Balance(Data.Copy(state[name].Data), formatter.text)
            assert(label == nil or type(label) == "string", "Reward Balance must return a string or nil")
            if label then parts[#parts + 1] = label end
        end
    end
    return table.concat(parts, " / ")
end

return RewardText
