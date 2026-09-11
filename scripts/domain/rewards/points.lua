local Data = require "scripts.domain.rewards.data"
local Points = {Version = 1, RequiredState = true}

function Points.Normalize(reward)
    if not Data.Integer(reward.Amount, 0, 1000000) then return nil, "Points Amount must be in 0..1000000" end
    return {Amount = reward.Amount}
end

function Points.NewState()
    return {Balance = 0}
end

function Points.ValidateState(state)
    if type(state) ~= "table" or not Data.Integer(state.Balance, 0, Data.MaxInteger) then
        return nil, "Invalid points balance"
    end
    return {Balance = state.Balance}
end

function Points.Apply(state, reward)
    if state.Balance > Data.MaxInteger - reward.Amount then return false, "Points capacity exceeded" end
    state.Balance = state.Balance + reward.Amount
    return true
end

return Points
