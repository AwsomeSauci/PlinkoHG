local Data = {}
Data.MaxInteger = 9007199254740991

function Data.Integer(value, minimum, maximum)
    return type(value) == "number" and value == value and value >= minimum
        and value <= maximum and value == math.floor(value)
end

function Data.Id(value)
    return type(value) == "string" and #value >= 1 and #value <= 64
        and value:match("^[%w%-_]+$") ~= nil
end

-- Reward definitions/state must be plain, finite, acyclic serializable data.
-- Reject executable values and metatables at the extension boundary.
local function copy(value, ancestors, depth)
    local kind = type(value)
    if kind == "number" then
        assert(value == value and math.abs(value) < math.huge, "Non-finite reward data")
    elseif kind == "table" then
        assert(depth < 16 and not ancestors[value] and getmetatable(value) == nil,
            "Reward data must be plain acyclic tables (depth < 16)")
        ancestors[value] = true
        local result = {}
        for key, item in pairs(value) do
            assert(type(key) == "string" or Data.Integer(key, 1, Data.MaxInteger), "Invalid reward data key")
            result[key] = copy(item, ancestors, depth + 1)
        end
        ancestors[value] = nil
        return result
    else
        assert(kind == "string" or kind == "boolean" or kind == "nil", "Non-serializable reward data")
    end
    return value
end

function Data.Copy(value)
    return copy(value, {}, 0)
end

function Data.Dense(value, maximum)
    if type(value) ~= "table" or getmetatable(value) ~= nil or #value < 1 or #value > maximum then return false end
    local count = 0
    for key in pairs(value) do
        if not Data.Integer(key, 1, #value) then return false end
        count = count + 1
    end
    -- Lua 5.1's # may point beyond a hole. Range checks alone would allow
    -- ipairs to silently skip the rest of an already promised reward pack.
    return count == #value
end

return Data
