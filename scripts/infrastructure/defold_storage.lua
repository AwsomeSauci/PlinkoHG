local DefoldStorage = {}
local filesystemScope = {}

-- Read bytes once: sys.load returns {} for both missing and inaccessible files.
-- Keeping I/O and decoding separate lets the store distinguish an unread slot
-- (never safe to overwrite) from readable corrupt data (backup may be used).
function DefoldStorage.New(systemApi, fileApi)
    local system, files = systemApi or sys, fileApi or io
    assert(type(system) == "table" and type(system.deserialize) == "function", "Defold storage API unavailable")
    -- Emscripten uses its own errno numbering; native supported targets use 2.
    local missingCode = system.get_sys_info().system_name == "HTML5" and 44 or 2
    return {
        OwnershipScope = (systemApi or fileApi) and {} or filesystemScope,
        Path = function(self, namespace, filename) return system.get_save_file(namespace, filename) end,
        Read = function(self, path)
            local file, openError, code = files.open(path, "rb")
            if not file then
                if code == missingCode then return {Status = "missing"} end
                return {Status = "unavailable", Error = tostring(openError)}
            end
            local called, bytes, readError = pcall(file.read, file, "*a")
            local closed, closeResult, closeError = pcall(file.close, file)
            if not called or bytes == nil or not closed or not closeResult then
                return {Status = "unavailable", Error = tostring(not called and bytes
                    or readError or not closed and closeResult or closeError)}
            end
            local decoded, value = pcall(system.deserialize, bytes)
            if not decoded then return {Status = "corrupt", Error = tostring(value)} end
            return {Status = "loaded", Value = value}
        end,
        Write = function(self, path, envelope) return system.save(path, envelope) end,
    }
end

return DefoldStorage
