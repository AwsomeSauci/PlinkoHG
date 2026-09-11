-- Buffer bounds and upload size contracts without a GPU. Real resource/mesh
-- integration is covered separately by tests/runtime/gui_smoke.gui_script.
local cases, uploads, rejectMessages = {}, {}, false
local function test(name, run) cases[#cases + 1] = {Name = name, Run = run} end
local function equal(a, b) assert(a == b, tostring(a) .. " ~= " .. tostring(b)) end

hash = function(value) return value end
vmath = {vector4 = function(x, y, z, w) return {x = x, y = y, z = z, w = w} end}
msg = {
    url = function() return {socket = "main", path = "game"} end,
    post = function() if rejectMessages then error("Mesh owner unavailable") end end,
}
buffer = {
    VALUE_TYPE_FLOAT32 = 1,
    create = function(count, declarations)
        local data = {count = count, streams = {}}
        for index, declaration in ipairs(declarations) do
            local values, limit = {}, count * declaration.count
            data.streams[declaration.name] = setmetatable({}, {
                __index = values,
                __newindex = function(self, key, value)
                    assert(key >= 1 and key <= limit, "Write outside resized buffer")
                    values[key] = value
                end,
            })
        end
        return data
    end,
    get_stream = function(data, name) return assert(data.streams[name]) end,
}
resource = {set_buffer = function(path, data) uploads[#uploads + 1] = data end}
local Renderer = require "scripts.ui.ball_renderer"

local function fixture(count)
    uploads = {}
    local renderer = Renderer.New(8, {MeshUrl = "mesh", BufferResource = "buffer"})
    local visuals = {}
    for index = 1, count do visuals[index] = Renderer.Acquire(renderer, {X = index, Y = 200}) end
    Renderer.Flush(renderer, true)
    return renderer, visuals
end

test("one survivor after a peak uploads a small buffer without stale vertices", function()
    local renderer, visuals = fixture(1024)
    equal(uploads[#uploads].count, 1024 * 24)
    for index = 2, #visuals do Renderer.Release(visuals[index]) end
    Renderer.Flush(renderer, true)
    equal(renderer.DrawnCount, 1); equal(uploads[#uploads].count, 32 * 24)
    equal(renderer.positions[19 * 3 - 2], 1 - 8) -- Sphere's first vertex, after its three trails.
    for vertex = 24, 32 * 24 - 1 do equal(renderer.colors[vertex * 4 + 4], 0) end
    local count = #uploads
    Renderer.Flush(renderer, true); equal(#uploads, count)
    Renderer.Move(visuals[1], {X = 100, Y = 300}, 1 / 60)
    Renderer.Flush(renderer, true); equal(#uploads, count + 1)
    equal(uploads[#uploads].count, 32 * 24)
    Renderer.Dispose(renderer)
end)

test("hidden empty boards release peak buffers and can start another flight", function()
    local renderer, visuals = fixture(1024)
    Renderer.Flush(renderer, false)
    for index, visual in ipairs(visuals) do Renderer.Release(visual) end
    Renderer.Flush(renderer, false)
    equal(renderer.DrawnCount, 0); equal(renderer.Capacity, 32)
    equal(uploads[#uploads].count, 32 * 24); assert(#renderer.free <= 32)
    local nextVisual = Renderer.Acquire(renderer, {X = 55, Y = 700})
    Renderer.Flush(renderer, true); equal(renderer.DrawnCount, 1)
    equal(nextVisual.X, 55); equal(nextVisual.History[1].Y, 700)
    Renderer.Dispose(renderer)
end)

test("capacity hysteresis avoids repeated reallocations near a boundary", function()
    local renderer, visuals = fixture(65)
    equal(renderer.Capacity, 128)
    for index = 34, 65 do Renderer.Release(visuals[index]) end
    Renderer.Flush(renderer, true); equal(renderer.Capacity, 128)
    Renderer.Release(visuals[33]); Renderer.Flush(renderer, true); equal(renderer.Capacity, 32)
    Renderer.Acquire(renderer, {X = 1, Y = 1}); Renderer.Flush(renderer, true)
    equal(renderer.Capacity, 64)
    Renderer.Dispose(renderer)
end)

test("failed mesh shutdown still releases Lua ownership and remains idempotent", function()
    local renderer = fixture(1)
    rejectMessages = true
    local ok, err = pcall(Renderer.Dispose, renderer)
    rejectMessages = false
    equal(ok, false); assert(err:find("Mesh owner unavailable", 1, true))
    equal(renderer.data, nil); equal(#renderer.active, 0); equal(#renderer.free, 0)
    equal(renderer.Capacity, 0); Renderer.Dispose(renderer)
end)

local failures = 0
for index, case in ipairs(cases) do
    local ok, err = pcall(case.Run)
    if not ok then failures = failures + 1 end
    io.write(ok and "PASS " or "FAIL ", case.Name, ok and "\n" or ": " .. tostring(err) .. "\n")
end
io.write(#cases - failures, "/", #cases, " renderer specifications passed\n")
assert(failures == 0, tostring(failures) .. " renderer specifications failed")
