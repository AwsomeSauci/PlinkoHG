local Strings = {}

local function quantity(amount, one, few, many)
    local last, ending = amount % 10, amount % 100
    local word = ending >= 11 and ending <= 14 and many
        or last == 1 and one or last >= 2 and last <= 4 and few or many
    return string.format("%.0f %s", amount, word)
end

local catalogs = {
    ru = {
        Score = "ОБЩИЙ СЧЁТ", Balls = "ШАРЫ", Stats = "СТАТИСТИКА",
        Drop = "БРОСИТЬ ШАР", Batch = "БРОСИТЬ %d", Grant = "+%d ШАРОВ",
        GrantHint = "для тестирования", DropHint = "ПРОБЕЛ", BatchHint = "КЛАВИША B",
        Ready = "Бросайте шары и получайте награды", Full = "Запас восстановлен",
        Refill = "+1 через %02d:%02d", RefillRule = "+1 шар каждые %d сек.  /  запас до %d",
        Flying = "Не завершено: %d", Award = "Получено: %s", Granted = "Добавлено шаров: %d",
        RewardPoints = function(n) return quantity(n, "очко", "очка", "очков") end,
        RewardBalls = function(n) return quantity(n, "шар", "шара", "шаров") end,
        RewardItem = "%s x%d",
        RewardBundle = "Наград: %d", RewardInventory = "Предметы: %s",
        RewardPending = "Награда ожидает выдачи. Повторяем попытку…",
        Empty = "Недостаточно шаров. Дождитесь восстановления",
        Limit = "Достигнут лимит текущей игры",
        SaveError = "Не удалось сохранить. Повторяем запись…",
        ServiceLoading = "Загрузка игры…", ServiceBusy = "Ожидаем подтверждение…",
        ServiceUnavailable = "Игра временно недоступна",
        ServiceHelp = "Попробуйте перезапустить игру",
        SaveRecovered = "Сохранение восстановлено из резервной копии",
        Offline = "За время отсутствия восстановлено: %d",
        SoundOn = "ЗВУК: ВКЛ", SoundOff = "ЗВУК: ВЫКЛ",
        StatsTitle = "СТАТИСТИКА ПОПАДАНИЙ", StatsClose = "ЗАКРЫТЬ",
        StatsHint = "D — статистика   /   ESC — закрыть",
        StatsEmpty = "Бросьте первый шар, чтобы увидеть распределение",
        DebugScore = "СЧЁТ", DebugHits = "ПОПАДАНИЯ", DebugActive = "НЕ ЗАВЕРШЕНО",
        DebugSettled = "ВЫДАНО НАГРАД",
        DebugBasket = "КОРЗИНА / НАГРАДА", DebugActual = "ФАКТ", DebugWeight = "ВЕС",
        DebugArchive = "Попаданий в прежние корзины: %d",
        ConfigError = "Ошибка конфигурации", ConfigHelp = "Проверьте config/game.lua и перезапустите игру",
        SaveUnavailable = "Прогресс недоступен", SaveHelp = "Сохранение оставлено без изменений. Перезапустите игру",
        Restored = "Продолжение сохранённой игры", Footer = "PLINKO LAB  /  РАЗРАБОТЧИК: IDDLEX",
    },
    en = {
        Score = "TOTAL SCORE", Balls = "BALLS", Stats = "STATISTICS",
        Drop = "DROP A BALL", Batch = "DROP %d", Grant = "+%d BALLS",
        GrantHint = "developer grant", DropHint = "SPACE", BatchHint = "KEY B",
        Ready = "Drop balls and collect rewards", Full = "Inventory replenished",
        Refill = "+1 in %02d:%02d", RefillRule = "+1 ball every %ds  /  refill cap %d",
        Flying = "Unsettled: %d", Award = "Received: %s", Granted = "Balls added: %d",
        RewardPoints = "%d points", RewardBalls = "%d balls", RewardItem = "%s x%d",
        RewardBundle = "%d rewards", RewardInventory = "Items: %s",
        RewardPending = "Reward pending. Retrying…",
        Empty = "Not enough balls. Wait for the next refill",
        Limit = "Session limit reached",
        SaveError = "Unable to save. Retrying…",
        ServiceLoading = "Loading game…", ServiceBusy = "Waiting for confirmation…",
        ServiceUnavailable = "Game temporarily unavailable",
        ServiceHelp = "Try restarting the game",
        SaveRecovered = "Recovered the backup save",
        Offline = "Replenished while away: %d", SoundOn = "SOUND: ON", SoundOff = "SOUND: OFF",
        StatsTitle = "LANDING STATISTICS", StatsClose = "CLOSE",
        StatsHint = "D — statistics   /   ESC — close",
        StatsEmpty = "Drop your first ball to see the distribution",
        DebugScore = "SCORE", DebugHits = "HITS", DebugActive = "UNSETTLED",
        DebugSettled = "AWARDS SETTLED",
        DebugBasket = "BASKET / REWARD", DebugActual = "ACTUAL", DebugWeight = "WEIGHT",
        DebugArchive = "Hits in previous baskets: %d",
        ConfigError = "Configuration error", ConfigHelp = "Check config/game.lua and restart the game",
        SaveUnavailable = "Progress unavailable", SaveHelp = "Your save was preserved. Please restart the game",
        Restored = "Saved game resumed", Footer = "PLINKO LAB  /  DEVELOPED BY IDDLEX",
    },
}

function Strings.New(locale)
    local catalog = catalogs[locale] or catalogs.ru
    return function(key, ...)
        local value = assert(catalog[key], "Missing UI string: " .. tostring(key))
        if type(value) == "function" then return value(...) end
        if select("#", ...) > 0 then return string.format(value, ...) end
        return value
    end
end

function Strings.Number(value)
    local text = string.format("%.0f", value)
    local formatted = text:reverse():gsub("(%d%d%d)", "%1 "):reverse()
    return formatted:gsub("^ ", "")
end

return Strings
