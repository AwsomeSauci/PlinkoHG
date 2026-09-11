local Data = require "scripts.domain.rewards.data"
local Ports = require "scripts.contracts.ports"
local Persistence = {}

local function duration(value, default)
    value = value == nil and default or value
    assert(type(value) == "number" and value > 0 and value < math.huge, "Persistence duration must be positive and finite")
    return value
end

local function validRevision(value)
    return type(value) == "string" and #value > 0 or Data.Integer(value, 0, Data.MaxInteger)
end

-- One logical operation at a time. Callback delivery is queued; only Poll
-- changes state. Retries use the original ID, expected revision and snapshot.
function Persistence.New(repository, options)
    options = options or {}
    return {repository = Ports.Require("SessionRepository", repository),
        timeout = duration(options.TimeoutSeconds, 15), retryDelay = duration(options.RetrySeconds, 1),
        nextId = 1, completions = {}, events = {}, phase = "new"}
end

local function emit(client, event) client.events[#client.events + 1] = event end

local function send(client)
    local operation = client.operation
    operation.attempt = operation.attempt + 1
    operation.elapsed, operation.retrying = 0, false
    local attempt, received = operation.attempt, false
    local function completed(result)
        if client.disposed or client.operation ~= operation or received then return end
        received = true
        local copied, value = pcall(Data.Copy, result)
        client.completions[#client.completions + 1] = {Operation = operation, Attempt = attempt,
            Result = copied and value or {Status = "failed", Error = "Non-serializable repository response"}}
    end
    local called, err = pcall(client.repository[operation.kind], client.repository,
        Data.Copy(operation.request), completed)
    if not called then completed({Status = "failed", Error = "Repository contract exception: " .. tostring(err)}) end
end

local function begin(client, kind, request)
    assert(not client.disposed and not client.operation, "Persistence already has an operation")
    assert(client.nextId <= Data.MaxInteger, "Persistence operation ID range exhausted")
    request.Id = client.nextId
    client.nextId = client.nextId + 1
    client.operation = {kind = kind, request = request, attempt = 0}
    send(client)
    return request.Id
end

function Persistence.Load(client)
    assert(client.phase == "new", "Load must run once per repository instance")
    client.phase = "loading"
    return begin(client, "Load", {})
end

function Persistence.Save(client, checkpoint)
    assert(client.phase == "ready", "Save requires a successfully loaded repository")
    local id = begin(client, "Save", {Snapshot = Data.Copy(checkpoint.Snapshot), ExpectedRevision = client.revision})
    client.operation.checkpoint = checkpoint
    return id
end

local function retry(client, detail)
    local operation = client.operation
    operation.elapsed, operation.retrying = 0, true
    if client.error ~= detail then emit(client, {Kind = "Retrying", Operation = operation.kind, Detail = detail}) end
    client.error = detail
end

local function fail(client, detail)
    client.phase, client.error, client.operation = "failed", detail, nil
    emit(client, {Kind = "Failed", Detail = detail})
end

function Persistence.Poll(client, dt)
    if client.disposed then return end
    assert(type(dt) == "number" and dt >= 0 and dt < math.huge, "Persistence.Poll requires finite delta")
    local completions = client.completions
    client.completions = {}
    local processed = false
    for index, completion in ipairs(completions) do
        local operation, result = client.operation, completion.Result
        if operation and operation == completion.Operation then
            -- A late success of a timed-out attempt still confirms this exact
            -- logical operation. Stale failures cannot cancel a newer attempt.
            if type(result) == "table" and result.Status == "ok" then
                processed = true
                if not validRevision(result.Revision) then
                    fail(client, "Repository success requires an opaque Revision token")
                else
                    client.phase, client.revision, client.error, client.operation = "ready", result.Revision, nil, nil
                    if operation.kind == "Load" then
                        emit(client, {Kind = "Loaded", Snapshot = result.Snapshot, Warning = result.Warning})
                    else
                        emit(client, {Kind = "Saved", Checkpoint = operation.checkpoint})
                    end
                end
            elseif completion.Attempt == operation.attempt then
                processed = true
                if type(result) == "table" and result.Status == "retry" then
                    retry(client, tostring(result.Error or "Storage temporarily unavailable"))
                else
                    fail(client, type(result) == "table" and tostring(result.Error or "Invalid repository result")
                        or "Invalid repository result")
                end
            end
        end
    end
    local operation = client.operation
    if operation and not processed then
        operation.elapsed = operation.elapsed + dt
        if operation.retrying then
            if operation.elapsed >= client.retryDelay then send(client) end
        elseif operation.elapsed >= client.timeout then
            retry(client, "Storage request timed out; awaiting confirmation")
        end
    end
    return #client.completions > 0
end

function Persistence.Retry(client)
    if client.operation and client.operation.retrying then send(client) end
end

function Persistence.GetState(client)
    return {Phase = client.phase, Busy = client.operation ~= nil, Error = client.error}
end

function Persistence.DrainEvents(client)
    local events = client.events
    client.events = {}
    return events
end

function Persistence.Dispose(client)
    if client.disposed then return end
    client.disposed, client.phase = true, "disposed"
    client.operation, client.completions, client.events = nil, {}, {}
    client.repository:Dispose()
end

return Persistence
