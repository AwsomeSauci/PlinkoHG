-- Structural interfaces: instance methods use colon calls. Construction checks
-- shape; behavioral guarantees are specified in Docs/SERVICE_CONTRACT.md.
local Ports = {}

---@class IClock
---@field Now fun(self: IClock): number Absolute economic time in seconds.

---@alias RepositoryRevision number|string
---@class RepositoryLoadRequest
---@field Id number Stable within the owned repository instance, reused on retry.
---@class RepositorySaveRequest: RepositoryLoadRequest
---@field Snapshot table Detached, immutable for the lifetime of this logical operation.
---@field ExpectedRevision RepositoryRevision Token from successful Load or preceding Save.
---@class RepositoryResult
---@field Status 'ok'|'retry'|'failed'|'conflict'
---@field Revision RepositoryRevision|nil Required on success, including missing saves.
---@field Snapshot table|nil Only Load; nil with Status=ok explicitly means no save exists.
---@field Warning string|nil Optional recovery diagnostic on successful Load.
---@field Error string|nil Diagnostic detail on failure.

---@class ISessionRepository
---@field Load fun(self: ISessionRepository, request: RepositoryLoadRequest, completed: fun(result: RepositoryResult)) Return value is ignored.
---@field Save fun(self: ISessionRepository, request: RepositorySaveRequest, completed: fun(result: RepositoryResult)) Return value is ignored.
---@field Dispose fun(self: ISessionRepository) Release transport/subscriptions; suppress future callbacks. Not a flush.
--- Both methods may complete inline or later on the owner thread; return is ignored.
--- Status: ok | retry | failed | conflict. A timeout is not proof of no write.
--- Duplicate Id must have identical meaning and be idempotent within the instance.
--- Repository owns globally unique transport keys and conditional writes/version checks.

---@class ISaveBackend
---@field OwnershipScope table|nil Shared identity for wrappers over the same storage inside one Lua state; defaults to the backend instance. Not an OS lock.
---@field Path fun(self: ISaveBackend, namespace: string, filename: string): string
---@field Read fun(self: ISaveBackend, path: string): table Status: missing | loaded (Value) | corrupt (Error) | unavailable (Error).
---@field Write fun(self: ISaveBackend, path: string, envelope: table): boolean Explicit true confirms a write.

---@class IFlightSimulation
---@field Configure fun(self: IFlightSimulation, basketCount: number)
---@field Create fun(self: IFlightSimulation, descriptor: table): table
---@field Update fun(self: IFlightSimulation, flight: table, dt: number): number[]|nil Updates X/Y/Done; returns crossed pegs.

---@class IGameView
---@field Configure fun(self: IGameView, config: table, initialModel: table|nil)
---@field Render fun(self: IGameView, state: GameState, dt: number)
---@field Notify fun(self: IGameView, code: string, amount: number|nil, detail: string|nil)
---@field SetStats fun(self: IGameView, enabled: boolean)
---@field SetMuted fun(self: IGameView, muted: boolean)
---@field PlaySound fun(self: IGameView, name: string, gain: number, speed: number)
---@field AddBall fun(self: IGameView, flight: table)
---@field MoveBall fun(self: IGameView, flight: table, dt: number)
---@field RemoveBall fun(self: IGameView, id: number|string)
---@field Contact fun(self: IGameView, peg: number)
---@field Award fun(self: IGameView, drop: table)
---@field CancelInput fun(self: IGameView)
---@field Dispose fun(self: IGameView)

local methods = {
    GameService = {"Open", "Execute", "Landed", "Update", "GetState", "DrainEvents", "Suspend", "Resume", "Flush", "Dispose"},
    SessionRepository = {"Load", "Save", "Dispose"},
    Clock = {"Now"},
    GameView = {"Configure", "Render", "Notify", "SetStats", "SetMuted", "PlaySound",
        "AddBall", "MoveBall", "RemoveBall", "Contact", "Award", "CancelInput", "Dispose"},
    FlightSimulation = {"Configure", "Create", "Update"},
}

function Ports.Require(name, instance)
    assert(type(instance) == "table", name .. " must be an instance")
    for index, method in ipairs(assert(methods[name], "Unknown port: " .. name)) do
        assert(type(instance[method]) == "function", name .. " requires " .. method .. "()")
    end
    return instance
end

return Ports
