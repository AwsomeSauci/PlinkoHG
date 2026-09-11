local SystemClock = {}

function SystemClock.New()
    return {Now = function() return os.time() end}
end

return SystemClock
