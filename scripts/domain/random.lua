local Random = {}

-- Park-Miller uses only integers below 2^53, so the sequence is identical
-- under Lua 5.1 doubles and LuaJIT. No dependency on global math.random state.
local modulus = 2147483647
local multiplier = 16807

function Random.New(seed)
    assert(type(seed) == "number" and seed == seed and math.abs(seed) < math.huge,
        "Random.New requires a finite seed")
    return { State = math.floor(math.abs(seed)) % (modulus - 1) + 1 }
end

function Random.NextSeed(random)
    random.State = random.State * multiplier % modulus
    return random.State
end

function Random.Next(random)
    return (Random.NextSeed(random) - 1) / (modulus - 1)
end

function Random.WeightedIndex(random, baskets, totalWeight)
    -- Keep the comparison in [0, 1). Multiplying a uniform sample by a
    -- subnormal total can round most samples onto only a handful of values
    -- and distort even equal basket weights. Normalised CDF avoids that loss.
    local sample = Random.Next(random)
    local cumulative = 0
    local lastPositive = 1
    for index, basket in ipairs(baskets) do
        cumulative = cumulative + basket.Weight / totalWeight
        if basket.Weight > 0 then
            lastPositive = index
            if sample < cumulative then
                return index
            end
        end
    end
    -- Floating-point rounding at the final boundary cannot select a zero weight.
    return lastPositive
end

return Random
