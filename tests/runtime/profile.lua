-- Optional, isolated CPU-side runtime profile. No GPU/FPS claim is made by a
-- headless engine. The real presenter, GUI/mesh and file adapter remain in use.
local Plinko = require "scripts.bootstrap.plinko"
local Presenter = require "scripts.presentation.game_presenter"
local DefoldStorage = require "scripts.infrastructure.defold_storage"
local BallRenderer = require "scripts.ui.ball_renderer"
local Data = require "scripts.domain.rewards.data"
local Profile = {}
local stepSeconds = 1 / 60

local function elapsed(started)
    local milliseconds = (socket.gettime() - started) * 1000
    assert(milliseconds >= 0, "Clock changed during profiling; discard this run")
    return milliseconds
end

local function summarize(samples)
    table.sort(samples)
    assert(#samples > 0, "Profile stage has no samples")
    return {Samples = #samples, P95 = samples[math.ceil(#samples * 0.95)], Max = samples[#samples]}
end

local function memory(profile, label)
    collectgarbage("collect")
    profile.report.MemoryKiB[label] = collectgarbage("count")
end

local function execute(profile, count)
    local started = socket.gettime()
    profile.presenter.service:Execute({Kind = "Drop", Count = count})
    Presenter.Update(profile.presenter, 0)
    profile.report.Commands[#profile.report.Commands + 1] = {Count = count, Milliseconds = elapsed(started)}
    assert(profile.presenter.service:GetState().Phase == "ready", "Profile command failed")
end

function Profile.New(parent)
    local directory = sys.get_config_string("qa.directory")
    assert(directory and directory ~= "", "Profile requires a disposable qa.directory")
    local profile = {samples = {Batch5 = {}, Stress = {}, Tail1 = {}, Idle = {}}, writes = {},
        report = {Variant = "headless", LogicalResolution = "720x1080", StepSeconds = stepSeconds,
            Commands = {}, MemoryKiB = {}, PeakCapacity = 0, MaxSaveBytes = 0}, frames = 0, phase = "Batch5"}
    local storage = DefoldStorage.New()
    storage.Path = function(self, namespace, filename) return directory .. "/" .. filename end
    local write = storage.Write
    storage.Write = function(self, path, envelope)
        local started = socket.gettime()
        local result = write(self, path, envelope)
        profile.writes[#profile.writes + 1] = elapsed(started)
        local file = assert(io.open(path, "rb"))
        profile.report.MaxSaveBytes = math.max(profile.report.MaxSaveBytes, assert(file:seek("end")))
        file:close()
        return result
    end
    local config = Data.Copy(require "config.game")
    config.InitialBalls = 1030 -- 5 ordinary + 1024 stress + 1 late survivor.
    -- Observe allocation without replacing the renderer or its engine API.
    local createRenderer = BallRenderer.New
    BallRenderer.New = function(...)
        local renderer = createRenderer(...)
        profile.renderer = renderer
        return renderer
    end
    local ok, err = pcall(function()
        profile.presenter = Plinko.Create(parent, {Config = config, Storage = storage,
            Clock = {Now = function() return 100 end}})
        profile.presenter.muted = true -- This GUI fixture has no sound components.
        Presenter.Start(profile.presenter)
    end)
    BallRenderer.New = createRenderer
    if not ok then
        if profile.presenter then pcall(Presenter.Dispose, profile.presenter) end
        error(err, 0)
    end
    memory(profile, "Baseline")
    execute(profile, 5)
    return profile
end

function Profile.Update(profile)
    profile.frames = profile.frames + 1
    assert(profile.frames <= 1500, "Profile flights failed to settle")
    local active = #profile.presenter.flights
    if profile.phase == "Stress" and active < 1024 and not profile.tailStarted then
        execute(profile, 1)
        profile.tailStarted = true
        active = #profile.presenter.flights
    end
    local stage = profile.phase
    if stage == "Stress" and active == 1 then
        stage = "Tail1"
        if not profile.report.MemoryKiB.Tail1 then memory(profile, "Tail1") end
    end
    local started = socket.gettime()
    Presenter.Update(profile.presenter, stepSeconds)
    local samples = profile.samples[stage]
    samples[#samples + 1] = elapsed(started)
    profile.report.PeakCapacity = math.max(profile.report.PeakCapacity, profile.renderer.Capacity)
    profile.report.MemoryKiB.PeakObserved = math.max(profile.report.MemoryKiB.PeakObserved or 0, collectgarbage("count"))
    local state = profile.presenter.service:GetState()
    assert(state.Phase == "ready" and not state.Error, "Profile persistence failed")
    if profile.phase == "Idle" then
        if #samples < 120 then return false end
        assert(state.Model.ActiveCount == 0 and state.Model.TotalHits == 1030, "Profile lost or duplicated a drop")
        assert(profile.renderer.Capacity == 32 and #profile.renderer.free <= 32, "Peak allocation retained")
        profile.report.FinalCapacity = profile.renderer.Capacity
        memory(profile, "Idle")
        profile.report.Updates = {}
        for name, values in pairs(profile.samples) do profile.report.Updates[name] = summarize(values) end
        profile.report.Writes = summarize(profile.writes)
        Presenter.Dispose(profile.presenter)
        profile.presenter = nil
        memory(profile, "Disposed")
        print("[Plinko PROFILE] " .. json.encode(profile.report))
        print("[Plinko PROFILE] SUCCESS: CPU-side runtime profile complete")
        return true
    elseif #profile.presenter.flights == 0 then
        if profile.phase == "Batch5" then
            profile.phase = "Stress"
            execute(profile, 1024)
        else
            profile.phase = "Idle"
        end
    end
    return false
end

function Profile.Dispose(profile)
    if profile.presenter then Presenter.Dispose(profile.presenter); profile.presenter = nil end
end

return Profile
