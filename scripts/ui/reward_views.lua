local Views = {Points = {}, Balls = {}, Item = {}}

function Views.Points.Format(reward, text, mode)
    if mode == "badge" or mode == "table" then return string.format("%.0f", reward.Amount) end
    return text("RewardPoints", reward.Amount)
end

function Views.Balls.Format(reward, text)
    return text("RewardBalls", reward.Amount)
end

function Views.Item.Format(reward, text)
    return text("RewardItem", reward.Name, reward.Amount)
end

function Views.Item.Balance(state, text)
    local ids, labels = {}, {}
    for id in pairs(state.Counts) do ids[#ids + 1] = id end
    table.sort(ids)
    for index, id in ipairs(ids) do labels[index] = text("RewardItem", state.Names[id], state.Counts[id]) end
    return #labels > 0 and text("RewardInventory", table.concat(labels, ", ")) or nil
end

return Views
