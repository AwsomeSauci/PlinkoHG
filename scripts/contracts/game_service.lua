---@class IGameService
---@field Open fun(self: IGameService)
---@field Execute fun(self: IGameService, command: GameCommand): number|string|nil Correlation ID, not success; nil outside ready lifetime.
---@field Landed fun(self: IGameService, dropId: number|string)
---@field Update fun(self: IGameService, dt: number)
---@field GetState fun(self: IGameService, includeDetails: boolean|nil): GameState
---@field DrainEvents fun(self: IGameService): GameEvent[]
---@field Suspend fun(self: IGameService)
---@field Resume fun(self: IGameService)
---@field Flush fun(self: IGameService, completed: fun(success: boolean, detail: string|nil)) Persist changes made before this call; completion may be deferred.
---@field Dispose fun(self: IGameService)
--- Open/Execute/Landed/Resume initiate work; they do not return its result.
--- DrainEvents delivers ordered results on the owner thread.
--- GetState is a detached read model, never I/O or an economic operation.
--- Phases: new -> opening -> ready | failed -> disposed. Busy gates new commands.
--- Ready supplies presentation Config; client visuals never need a Session.
--- Events: Ready, Started, Awarded, CommandStatus, Notice, SaveFailed, RewardFailed.
--- CommandStatus: Id, Command, Status (Pending | Succeeded | Rejected), Code, Amount.
--- Pending is nonterminal; a retained command is never reported as Rejected.
--- At most one terminal status per command. Failed/disposed ends delivery;
--- a pending command without acknowledgement retains an unconfirmed outcome.
--- Each Execute is a new intent. Transport retries reuse its ID inside the service.
--- A service owns command correlation, deduplication and durable retry semantics.
--- Landed is a visual acknowledgement, NEVER proof of entitlement for a backend.
--- Dispose is idempotent, cancels subscriptions and suppresses late responses.
local Ports = require "scripts.contracts.ports"
local GameService = {}

---@class GameCommand
---@field Kind 'Drop'|'Grant'
---@field Count number|nil Only for Drop; never a client-selected reward/outcome.

---@class GameState
---@field Phase 'new'|'opening'|'ready'|'failed'|'disposed'
---@field Busy boolean Waiting for an operation; new economy commands are disabled.
---@field Model table|nil Detached projection, not a domain Session or save payload.
---@field Error string|nil Diagnostic detail, separate from user-facing text.

---@class GameEvent
---@field Kind string Ordered event discriminant; payload schema is documented.

---@param instance IGameService
---@return IGameService

function GameService.Require(instance)
    return Ports.Require("GameService", instance)
end

return GameService
