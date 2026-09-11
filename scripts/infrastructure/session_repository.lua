local SaveStore = require "scripts.infrastructure.save_store"
local Data = require "scripts.domain.rewards.data"
local SessionRepository = {}
local owners = setmetatable({}, {__mode = "k"})

-- The local adapter completes inline, using the same asynchronous contract as
-- a future cloud/platform adapter. SaveStore remains a private synchronous detail.
function SessionRepository.New(config, registry, backend, namespace)
    local store = SaveStore.New(config, backend, registry, namespace)
    local disposed, loaded, loadResult, lastId, lastResult = false, false, nil, nil, nil
    local scope = store.Backend and (store.Backend.OwnershipScope or store.Backend)
    local owner, ownedPath = {}, nil
    local function release()
        if ownedPath and owners[scope] and owners[scope][ownedPath] == owner then
            owners[scope][ownedPath] = nil
        end
        ownedPath = nil
    end
    return {
        Load = function(self, request, completed)
            if disposed then return end
            if not loaded then
                -- Separate namespaces/backends remain independent. The default
                -- filesystem adapter shares a scope across its instances.
                if not store.Error then
                    local path = store.Paths[1] .. "\0" .. store.Paths[2]
                    owners[scope] = owners[scope] or {}
                    if owners[scope][path] then
                        loaded, loadResult = true, {Status = "failed", Error = "Session already open in this process"}
                        completed(Data.Copy(loadResult)); return
                    end
                    owners[scope][path], ownedPath = owner, path
                end
                local snapshot, warning = SaveStore.Load(store)
                if store.Error or (not snapshot and warning) then
                    loadResult = {Status = "failed", Error = store.Error or warning}
                    release()
                else
                    loadResult = {Status = "ok", Snapshot = snapshot, Warning = warning, Revision = store.Revision}
                end
                loaded = true
            end
            completed(Data.Copy(loadResult))
        end,
        Save = function(self, request, completed)
            if disposed then return end
            if not loaded or loadResult.Status ~= "ok" then
                completed({Status = "failed", Error = "Save requires a successful Load"}); return
            end
            if request.Id == lastId then completed(Data.Copy(lastResult)); return end
            if request.ExpectedRevision ~= store.Revision then
                completed({Status = "conflict", Error = "Save revision conflict"}); return
            end
            local saved, err, status = SaveStore.Save(store, request.Snapshot)
            local result = saved and {Status = "ok", Revision = store.Revision}
                or {Status = status or "failed", Error = err}
            if saved then lastId, lastResult = request.Id, result end
            completed(Data.Copy(result))
        end,
        Dispose = function() disposed = true; release() end,
    }
end

return SessionRepository
