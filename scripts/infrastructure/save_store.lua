local Session = require "scripts.domain.session"
local DefoldStorage = require "scripts.infrastructure.defold_storage"

local SaveStore = {Version = 3}
local maxRevision = 9007199254740990

-- The optional backend makes storage failures testable without Defold.
-- The default adapter separates missing, unreadable and corrupt files.
-- Backend/path initialization errors are terminal for this store. Recovery
-- requires a new startup + Load before Save, so an unread existing session
-- cannot accidentally be overwritten by the fresh in-memory state.
function SaveStore.New(config, backend, registry, namespace)
    local storage = backend or DefoldStorage.New()
    local store = { Config = config, Registry = registry, Backend = storage, Revision = 0, Slot = 0, Paths = {} }
    if type(storage) ~= "table" or type(storage.Path) ~= "function"
        or type(storage.Read) ~= "function" or type(storage.Write) ~= "function" then
        store.Error = "Save backend unavailable"
        return store
    end
    -- No legacy migration by product decision; previous files are untouched.
    for index, filename in ipairs({ "session-v3-a", "session-v3-b" }) do
        local ok, path = pcall(storage.Path, storage, namespace or "PlinkoHG", filename)
        if not ok or type(path) ~= "string" or path == "" then
            store.Error = "Cannot resolve save path: " .. tostring(path)
            return store
        end
        store.Paths[index] = path
    end
    return store
end

local function loadSlot(store, index)
    local ok, result = pcall(store.Backend.Read, store.Backend, store.Paths[index])
    if not ok then return nil, tostring(result), true end
    if type(result) ~= "table" then return nil, "Invalid storage read result", true end
    if result.Status == "missing" then return nil end
    if result.Status == "corrupt" then return nil, tostring(result.Error) end
    if result.Status ~= "loaded" then return nil, tostring(result.Error or "Storage unavailable"), true end
    local envelope = result.Value
    if type(envelope) == "table" then
        local futureEnvelope = type(envelope.Version) == "number" and envelope.Version > SaveStore.Version
        local payload = envelope.Payload
        local futurePayload = type(payload) == "table"
            and type(payload.Version) == "number" and payload.Version > Session.SnapshotVersion
        if futureEnvelope or futurePayload then
            return nil, "Save requires a newer application version", true
        end
    end
    if type(envelope) ~= "table" or envelope.Version ~= SaveStore.Version
        or type(envelope.Revision) ~= "number" or envelope.Revision ~= envelope.Revision
        or envelope.Revision < 1 or envelope.Revision > maxRevision
        or envelope.Revision ~= math.floor(envelope.Revision) then
        return nil, "Invalid save envelope"
    end
    local snapshot, validationError, incompatible = Session.ValidateSnapshot(store.Config, envelope.Payload, store.Registry)
    if not snapshot then
        return nil, validationError, incompatible
    end
    return { Revision = envelope.Revision, Payload = snapshot, Slot = index }
end

function SaveStore.Load(store)
    if store.Error then
        return nil, store.Error
    end
    local chosen
    local unsafe = false
    local errors = {}
    for index = 1, 2 do
        local slot, loadError, incompatible = loadSlot(store, index)
        unsafe = unsafe or incompatible == true
        if slot and (not chosen or slot.Revision > chosen.Revision) then
            chosen = slot
        end
        if loadError then
            errors[#errors + 1] = "Slot " .. index .. ": " .. loadError
        end
    end
    local warning = #errors > 0 and table.concat(errors, "; ") or nil
    if unsafe or (not chosen and warning) then
        -- An unread slot may contain a newer revision/schema. A compatible
        -- backup cannot justify overwriting it. Reopen after fixing access or
        -- incompatibility; with no valid backup, corruption is also terminal.
        store.Error = "Cannot safely load session. " .. warning
        return nil, store.Error
    end
    if chosen then
        store.Revision = chosen.Revision
        store.Slot = chosen.Slot
        return chosen.Payload, warning
    end
    return nil, warning
end

function SaveStore.Save(store, snapshot)
    if store.Error then
        return false, store.Error, "failed"
    end
    if store.Revision >= maxRevision then
        return false, "Save revision limit reached", "failed"
    end
    local validated, validationError = Session.ValidateSnapshot(store.Config, snapshot, store.Registry)
    if not validated then
        return false, validationError, "failed"
    end
    -- Detect changes made since this store loaded/last wrote, including a
    -- deleted save or a newer schema. This is optimistic detection, NOT an
    -- atomic inter-process lock: hosts must still enforce one writer per path.
    local current = {Config = store.Config, Backend = store.Backend, Registry = store.Registry,
        Paths = store.Paths, Revision = 0, Slot = 0}
    SaveStore.Load(current)
    if current.Error then return false, current.Error, "failed" end
    if current.Revision ~= store.Revision or current.Slot ~= store.Slot then
        return false, "Session changed outside this instance; reopen to load the latest progress", "conflict"
    end
    local slot = store.Slot == 1 and 2 or 1
    local revision = store.Revision + 1
    -- Always overwrite the other slot. A failed/truncated write leaves the
    -- last complete snapshot available. Advance the revision only on success.
    local ok, result = pcall(store.Backend.Write, store.Backend, store.Paths[slot], {
        Version = SaveStore.Version,
        Revision = revision,
        Payload = validated,
    })
    -- The backend must explicitly confirm a successful write.
    if not ok or result ~= true then
        return false, "Cannot save session: " .. tostring(result), "retry"
    end
    store.Revision = revision
    store.Slot = slot
    return true
end

return SaveStore
