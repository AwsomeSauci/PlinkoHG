local Config = require "scripts.domain.config"
local Registry = require "scripts.domain.rewards.registry"
local LocalGameService = require "scripts.application.local_game_service"
local SessionRepository = require "scripts.infrastructure.session_repository"
local SystemClock = require "scripts.infrastructure.system_clock"
local FlightSimulator = require "scripts.simulation.flight_simulator"
local Presenter = require "scripts.presentation.game_presenter"
local GameView = require "scripts.ui.game_view"
local Ports = require "scripts.contracts.ports"
local Plinko = {}

-- Only composition selects concrete implementations. Injecting Service skips
-- local config, handlers and repository construction entirely.
function Plinko.Create(parent, options)
    options = options or {}
    local rewardTypes = options.RewardTypes or require "config.reward_types"
    local service = options.Service
    if not service then
        local registry = Registry.New(rewardTypes)
        local config, err = Config.Validate(options.Config or require "config.game", registry)
        assert(config, err)
        local repository = options.Repository or SessionRepository.New(config, registry, options.Storage, options.StorageNamespace)
        service = LocalGameService.New(config, registry, repository, options.Clock or SystemClock.New(), options.Persistence)
    end
    local view = options.View
    local ok, presenter = pcall(function()
        Ports.Require("GameService", service)
        local simulation = Ports.Require("FlightSimulation", options.Simulation or FlightSimulator.New())
        view = view or GameView.New(parent, rewardTypes, options.Render)
        return Presenter.New(service, view, simulation)
    end)
    if ok then return presenter, view end
    local errors = {tostring(presenter)}
    for index, instance in ipairs({service, view or {}}) do
        if type(instance) == "table" and type(instance.Dispose) == "function" then
            local disposed, err = pcall(instance.Dispose, instance)
            if not disposed then errors[#errors + 1] = "Construction cleanup: " .. tostring(err) end
        end
    end
    error(table.concat(errors, "\n"), 0)
end

return Plinko
