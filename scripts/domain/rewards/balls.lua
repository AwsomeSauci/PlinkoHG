local Data = require "scripts.domain.rewards.data"
local Balls = {Version = 1, RequiredState = true}

function Balls.Normalize(reward, context)
    if not Data.Integer(reward.Amount, 1, context.Saved and 1000000 or context.MaxInventory) then
        return nil, "Balls Amount must fit MaxInventory"
    end
    return {Amount = reward.Amount}
end

function Balls.ValidateBundle(rewards, context)
    local total = 0
    for index, reward in ipairs(rewards) do total = total + reward.Amount end
    if total > context.MaxInventory then return false, "Combined ball reward cannot fit MaxInventory" end
    return true
end

function Balls.NewState(context)
    return {Balance = context.InitialBalls}
end

function Balls.ValidateState(state)
    -- Lowering a config limit must not destroy an already owned balance.
    if type(state) ~= "table" or not Data.Integer(state.Balance, 0, Data.MaxInteger) then
        return nil, "Invalid ball balance"
    end
    return {Balance = state.Balance}
end

function Balls.Apply(state, reward, context)
    if state.Balance > context.MaxInventory - reward.Amount then return false, "Ball inventory is full" end
    state.Balance = state.Balance + reward.Amount
    return true
end

return Balls
