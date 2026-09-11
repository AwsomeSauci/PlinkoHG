local Data = require "scripts.domain.rewards.data"
local Item = {Version = 1}

function Item.Normalize(reward)
    if not Data.Id(reward.ItemId) or not Data.Integer(reward.Amount, 1, 1000000) then
        return nil, "Item requires a stable ItemId and Amount in 1..1000000"
    end
    if type(reward.Name) ~= "string" or #reward.Name < 1 or #reward.Name > 120
        or reward.Name:find("[%c]") then return nil, "Item requires a readable Name (1..120 bytes)" end
    return {ItemId = reward.ItemId, Name = reward.Name, Amount = reward.Amount}
end

function Item.NewState()
    return {Counts = {}, Names = {}}
end

function Item.ValidateState(state)
    if type(state) ~= "table" or type(state.Counts) ~= "table" or type(state.Names) ~= "table" then
        return nil, "Invalid item inventory"
    end
    local result = Item.NewState()
    for id, count in pairs(state.Counts) do
        local name = state.Names[id]
        if not Data.Id(id) or not Data.Integer(count, 1, Data.MaxInteger)
            or type(name) ~= "string" or #name < 1 or #name > 120 or name:find("[%c]") then
            return nil, "Invalid saved item"
        end
        result.Counts[id], result.Names[id] = count, name
    end
    for id in pairs(state.Names) do
        if not result.Counts[id] then return nil, "Orphaned item name" end
    end
    return result
end

function Item.Apply(state, reward)
    local owned = state.Counts[reward.ItemId] or 0
    if owned > Data.MaxInteger - reward.Amount then return false, "Item capacity exceeded" end
    state.Counts[reward.ItemId] = owned + reward.Amount
    state.Names[reward.ItemId] = reward.Name
    return true
end

return Item
