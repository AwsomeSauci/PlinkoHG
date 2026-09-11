local Registry = require "scripts.domain.rewards.registry"
local Data = require "scripts.domain.rewards.data"
local Config = {}

local function isNumber(value, minimum, maximum)
    return type(value) == "number" and value == value
        and value >= minimum and value <= maximum
end

local function isInteger(value, minimum, maximum)
    return isNumber(value, minimum, maximum) and value == math.floor(value)
end

local function validId(value)
    return type(value) == "string" and #value >= 1 and #value <= 64
        and value:match("^[%w%-_]+$") ~= nil
end

function Config.Validate(raw, registry)
    if type(raw) ~= "table" or raw.Version ~= 2 then
        return nil, "Config.Version must be 2"
    end
    if type(registry) ~= "table" then return nil, "Config requires a reward registry" end

    local limits = {
        InitialBalls = { 0, 1000000 },
        RefillCap = { 1, 1000000 },
        RefillSeconds = { 1, 86400 },
        BatchSize = { 1, 1000000 },
        GrantSize = { 1, 1000000 },
        MaxInventory = { 1, 1000000 },
    }
    local config = { Version = 2, Baskets = {}, TotalWeight = 0 }
    for field, range in pairs(limits) do
        if not isInteger(raw[field], range[1], range[2]) then
            return nil, "Config." .. field .. " must be an integer in "
                .. range[1] .. ".." .. range[2]
        end
        config[field] = raw[field]
    end
    if config.InitialBalls > config.MaxInventory or config.RefillCap > config.MaxInventory then
        return nil, "InitialBalls and RefillCap cannot exceed MaxInventory"
    end
    if config.BatchSize > config.MaxInventory then
        return nil, "BatchSize cannot exceed MaxInventory"
    end
    if raw.Locale ~= "ru" and raw.Locale ~= "en" then
        return nil, "Config.Locale must be ru or en"
    end
    config.Locale = raw.Locale

    if type(raw.Baskets) ~= "table" or #raw.Baskets < 2 or #raw.Baskets > 16 then
        return nil, "Config.Baskets must contain 2..16 baskets"
    end
    local count = #raw.Baskets
    for key in pairs(raw.Baskets) do
        if not isInteger(key, 1, count) then
            return nil, "Config.Baskets must be a dense array"
        end
    end
    local ids = {}
    for index = 1, count do
        local basket = raw.Baskets[index]
        if type(basket) ~= "table" or not validId(basket.Id) or ids[basket.Id] then
            return nil, "Basket " .. index .. " requires a unique stable Id"
        end
        if not isNumber(basket.Weight, 0, 1000000) then
            return nil, "Basket " .. index .. " Weight must be finite and in 0..1000000"
        end
        if basket.Points ~= nil then return nil, "Basket " .. index .. " uses obsolete Points; use Rewards" end
        local rewards, rewardError = Registry.Normalize(registry, basket.Rewards, config)
        if not rewards then return nil, "Basket " .. index .. ": " .. rewardError end
        if type(basket.Color) ~= "string" or not basket.Color:match("^%x%x%x%x%x%x$") then
            return nil, "Basket " .. index .. " Color must be a six-digit RGB hex string"
        end
        ids[basket.Id] = true
        config.Baskets[index] = {
            Id = basket.Id,
            Weight = basket.Weight,
            Rewards = rewards,
            Color = basket.Color:upper(),
        }
        config.TotalWeight = config.TotalWeight + basket.Weight
    end
    if config.TotalWeight <= 0 then
        return nil, "At least one basket must have positive Weight"
    end
    local initial, stateError = Registry.ValidateState(registry, {}, config, true)
    if not initial or not initial.points or not initial.balls
        or not Data.Integer(initial.points.Data.Balance, 0, Data.MaxInteger)
        or initial.balls.Data.Balance ~= config.InitialBalls then
        return nil, stateError or "Plinko requires points and balls reward handlers"
    end
    return config
end

return Config
