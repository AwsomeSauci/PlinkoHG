local Storage = require "scripts.infrastructure.defold_storage"
local cases = {}
local function test(name, run) cases[#cases + 1] = {Name = name, Run = run} end
local function equal(a, b) assert(a == b, tostring(a) .. " ~= " .. tostring(b)) end
local function system(platform)
    return {
        get_sys_info = function() return {system_name = platform or "Windows"} end,
        get_save_file = function(app, name) return app .. "/" .. name end,
        deserialize = function(bytes) equal(bytes, "serialized"); return {Version = 3} end,
        save = function() return true end,
    }
end

test("native and HTML5 missing errors are distinct from access failures", function()
    for index, platform in ipairs({{Name = "Windows", Missing = 2}, {Name = "HTML5", Missing = 44}}) do
        for _, code in ipairs({platform.Missing, 13, 5, 28}) do
            local storage = Storage.New(system(platform.Name), {open = function() return nil, "open error", code end})
            equal(storage:Read("slot").Status, code == platform.Missing and "missing" or "unavailable")
        end
        local unknown = Storage.New(system(platform.Name), {open = function() return nil, "unknown error" end})
        equal(unknown:Read("slot").Status, "unavailable")
    end
end)

test("read failures always close the handle and never reach the decoder", function()
    for index, read in ipairs({function() return nil, "I/O error" end, function() error("Read exception") end}) do
        local closed = 0
        local api = system(); api.deserialize = function() error("Must not decode") end
        local storage = Storage.New(api, {open = function()
            return {read = read, close = function() closed = closed + 1; return true end}
        end})
        local result = storage:Read("slot")
        equal(result.Status, "unavailable"); equal(closed, 1)
        assert(not result.Error:find("Must not decode", 1, true))
    end
end)

test("failed close does not report successful file access", function()
    local storage = Storage.New(system(), {open = function()
        return {read = function() return "serialized" end, close = function() return nil, "Close failure" end}
    end})
    local result = storage:Read("slot")
    equal(result.Status, "unavailable"); equal(result.Error, "Close failure")
end)

test("readable malformed bytes are corruption, not an unavailable or missing slot", function()
    local closed = false
    local storage = Storage.New(system(), {open = function()
        return {read = function() return "" end, close = function() closed = true; return true end}
    end})
    equal(storage:Read("slot").Status, "corrupt"); assert(closed)
end)

test("adapter decodes the same bytes read and returns explicit write acknowledgement", function()
    local opened, closed = 0, 0
    local storage = Storage.New(system(), {open = function(path, mode)
        opened = opened + 1; equal(path, "game/slot"); equal(mode, "rb")
        return {read = function() return "serialized" end, close = function() closed = closed + 1; return true end}
    end})
    local path = storage:Path("game", "slot")
    local read = storage:Read(path)
    equal(read.Status, "loaded"); equal(read.Value.Version, 3)
    equal(opened, 1); equal(closed, 1); equal(storage:Write(path, read.Value), true)
end)

local failures = 0
for index, case in ipairs(cases) do
    local ok, err = pcall(case.Run)
    if not ok then failures = failures + 1 end
    io.write(ok and "PASS " or "FAIL ", case.Name, ok and "\n" or ": " .. tostring(err) .. "\n")
end
io.write(#cases - failures, "/", #cases, " storage specifications passed\n")
assert(failures == 0, tostring(failures) .. " storage specifications failed")
