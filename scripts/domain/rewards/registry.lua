local Data = require "scripts.domain.rewards.data"
local Registry = {}

function Registry.New(registrations)
    assert(Data.Dense(registrations, Data.MaxInteger), "Reward registrations must be a non-empty dense array")
    local registry = {handlers = {}, order = {}}
    for index, entry in ipairs(registrations) do
        local handler = entry.Handler
        assert(Data.Id(entry.Type) and not registry.handlers[entry.Type], "Reward type must be unique")
        assert(type(handler) == "table" and Data.Integer(handler.Version, 1, 1000000), "Reward handler requires Version")
        for methodIndex, method in ipairs({"Normalize", "NewState", "ValidateState", "Apply"}) do
            assert(type(handler[method]) == "function", "Reward handler requires " .. method)
        end
        assert(handler.ValidateBundle == nil or type(handler.ValidateBundle) == "function", "ValidateBundle must be a function")
        registry.handlers[entry.Type] = handler
        registry.order[#registry.order + 1] = entry.Type
    end
    return registry
end

local function context(config, saved)
    -- Extensions receive design limits, never the live Session or engine API.
    return {InitialBalls = config.InitialBalls, MaxInventory = config.MaxInventory, Saved = saved == true}
end

function Registry.Normalize(registry, raw, config, saved)
    if not Data.Dense(raw, 32) then return nil, "Rewards must be a dense array of 1..32 entries" end
    local normalized, grouped = {}, {}
    for index, reward in ipairs(raw) do
        if type(reward) ~= "table" then return nil, "Invalid reward entry" end
        local handler = registry.handlers[reward.Type]
        if not handler or (reward.Version ~= nil and reward.Version ~= handler.Version)
            or (saved and reward.Version == nil) then
            return nil, "Unknown reward type/version: " .. tostring(reward.Type), true
        end
        local ok, value, err = pcall(function()
            return handler.Normalize(Data.Copy(reward), context(config, saved))
        end)
        if not ok or not value then return nil, tostring(ok and err or value) end
        local copied, payload = pcall(Data.Copy, value)
        if not copied or type(payload) ~= "table" then return nil, "Invalid normalized reward data" end
        payload.Type, payload.Version = reward.Type, handler.Version
        normalized[index] = payload
        grouped[reward.Type] = grouped[reward.Type] or {}
        grouped[reward.Type][#grouped[reward.Type] + 1] = payload
    end
    -- Config-only feasibility checks must not invalidate already committed
    -- rewards when a later config reduces inventory capacity.
    if not saved then
        for name, rewards in pairs(grouped) do
            local handler = registry.handlers[name]
            if handler.ValidateBundle then
                local ok, valid, err = pcall(handler.ValidateBundle, Data.Copy(rewards), context(config))
                if not ok or not valid then return nil, tostring(ok and err or valid) end
            end
        end
    end
    return normalized
end

function Registry.ValidateState(registry, raw, config, fresh)
    if type(raw) ~= "table" then return nil, "Invalid reward state" end
    for name, entry in pairs(raw) do
        local handler = registry.handlers[name]
        if not handler or type(entry) ~= "table" or entry.Version ~= handler.Version then
            return nil, "Unknown reward state type/version: " .. tostring(name), true
        end
    end
    local result = {}
    for index, name in ipairs(registry.order) do
        local handler, entry = registry.handlers[name], raw[name]
        if not entry and handler.RequiredState and not fresh then return nil, "Missing reward state: " .. name end
        local ok, value, err = pcall(function()
            local state = entry and Data.Copy(entry.Data) or handler.NewState(context(config))
            return handler.ValidateState(state, context(config))
        end)
        if not ok or not value then return nil, tostring(ok and err or value) end
        local copied, data = pcall(Data.Copy, value)
        if not copied or type(data) ~= "table" then return nil, "Invalid reward state data" end
        result[name] = {Version = handler.Version, Data = data}
    end
    return result
end

function Registry.NewState(registry, config)
    return assert(Registry.ValidateState(registry, {}, config, true))
end

function Registry.Apply(registry, state, rewards, config)
    -- Copy only touched namespaces. No partial state escapes if any extension
    -- rejects a reward, throws, or returns non-serializable state.
    local draft, touched = {}, {}
    for name, entry in pairs(state) do draft[name] = entry end
    for index, reward in ipairs(rewards) do
        local handler = registry.handlers[reward.Type]
        if not handler or reward.Version ~= handler.Version then return nil, "Unknown reward type/version" end
        if not touched[reward.Type] then
            draft[reward.Type] = Data.Copy(state[reward.Type])
            touched[reward.Type] = true
        end
        local ok, applied, err = pcall(handler.Apply, draft[reward.Type].Data, Data.Copy(reward), context(config))
        if not ok or applied ~= true then return nil, tostring(ok and err or applied) end
    end
    for name in pairs(touched) do
        local ok, valid, err = pcall(registry.handlers[name].ValidateState, draft[name].Data, context(config))
        if not ok or not valid then return nil, tostring(ok and err or valid) end
        local copied, data = pcall(Data.Copy, valid)
        if not copied or type(data) ~= "table" then return nil, "Reward handler returned invalid state" end
        draft[name] = {Version = registry.handlers[name].Version, Data = data}
    end
    return draft
end

return Registry
