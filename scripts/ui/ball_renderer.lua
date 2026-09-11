local Theme = require "scripts.ui.theme"
local BallRenderer = {}
local corners = {-1, -1, 1, -1, 1, 1, -1, -1, 1, 1, -1, 1}
local verticesPerBall = 24 -- Three trail quads and one sphere quad.
local minimumCapacity = 32

function BallRenderer.New(radius, options)
    options = options or {}
    local owner = msg.url()
    local mesh = options.MeshUrl or msg.url(owner.socket, owner.path, "balls")
    return {
        Mesh = mesh, Resource = options.BufferResource or hash("/assets/render/balls.bufferc"), Radius = radius,
        Capacity = 0, DrawnCount = 0, active = {}, free = {},
        color = Theme.Color(Theme.Gold),
    }
end

local function reserve(renderer, count)
    -- A fourfold drop is enough to shrink; the gap avoids resizing every time
    -- the active count oscillates near a power-of-two boundary.
    if count <= renderer.Capacity
        and (renderer.Capacity <= minimumCapacity or count > renderer.Capacity / 4) then return false end
    local capacity = minimumCapacity
    while capacity < count do capacity = capacity * 2 end
    local vertexCount = capacity * verticesPerBall
    renderer.data = buffer.create(vertexCount, {
        {name = hash("position"), type = buffer.VALUE_TYPE_FLOAT32, count = 3},
        {name = hash("texcoord0"), type = buffer.VALUE_TYPE_FLOAT32, count = 2},
        {name = hash("ball_color"), type = buffer.VALUE_TYPE_FLOAT32, count = 4},
    })
    renderer.positions = buffer.get_stream(renderer.data, "position")
    renderer.uvs = buffer.get_stream(renderer.data, "texcoord0")
    renderer.colors = buffer.get_stream(renderer.data, "ball_color")
    for index = 1, vertexCount * 3 do renderer.positions[index] = 0 end
    for index = 1, vertexCount * 2 do renderer.uvs[index] = 0 end
    for index = 1, vertexCount * 4 do renderer.colors[index] = 0 end
    renderer.Capacity = capacity
    renderer.previousCount = 0
    renderer.dirty = true
    -- Free visuals are only a small reuse cache, never a permanent peak ledger.
    while #renderer.free > minimumCapacity do renderer.free[#renderer.free] = nil end
    return true
end

function BallRenderer.Acquire(renderer, flight)
    local visual = table.remove(renderer.free) or {History = {{}, {}, {}}}
    visual.owner, visual.X, visual.Y = renderer, flight.X, flight.Y
    for index, point in ipairs(visual.History) do point.X, point.Y = flight.X, flight.Y end
    renderer.active[#renderer.active + 1] = visual
    visual.index = #renderer.active
    renderer.dirty = true
    return visual
end

function BallRenderer.Move(visual, flight, dt)
    visual.owner.dirty = true
    visual.X, visual.Y = flight.X, flight.Y
    local x, y = flight.X, flight.Y
    local smoothing = 1 - math.exp(-28 * dt)
    for index, point in ipairs(visual.History) do
        point.X = point.X + (x - point.X) * smoothing
        point.Y = point.Y + (y - point.Y) * smoothing
        x, y = point.X, point.Y
    end
end

function BallRenderer.Release(visual)
    local renderer, index = visual.owner, visual.index
    if not index then return end
    local last = renderer.active[#renderer.active]
    renderer.active[index], last.index = last, index
    renderer.active[#renderer.active] = nil
    visual.index = nil
    if #renderer.free < minimumCapacity then renderer.free[#renderer.free + 1] = visual end
    renderer.dirty = true
end

local function quad(renderer, firstVertex, x, y, radius, alpha)
    local positions, uvs, colors = renderer.positions, renderer.uvs, renderer.colors
    local color = renderer.color
    for corner = 0, 5 do
        local vertex = firstVertex + corner
        local u, v = corners[corner * 2 + 1], corners[corner * 2 + 2]
        local p, t, c = vertex * 3, vertex * 2, vertex * 4
        positions[p + 1], positions[p + 2], positions[p + 3] = x + u * radius, y + v * radius, 0
        uvs[t + 1], uvs[t + 2] = u, v
        colors[c + 1], colors[c + 2], colors[c + 3], colors[c + 4] = color.x, color.y, color.z, alpha
    end
end

function BallRenderer.Flush(renderer, visible)
    local count = #renderer.active
    local enabled = visible ~= false and count > 0
    if renderer.enabled ~= enabled then
        msg.post(renderer.Mesh, enabled and "enable" or "disable")
        renderer.enabled = enabled
    end
    if not enabled then
        renderer.DrawnCount = 0
        if count == 0 and renderer.Capacity > minimumCapacity and reserve(renderer, 0) then
            resource.set_buffer(renderer.Resource, renderer.data)
        end
        return
    end
    renderer.DrawnCount = count
    if not renderer.dirty then return end
    reserve(renderer, count)
    for index, visual in ipairs(renderer.active) do
        local firstVertex = (index - 1) * verticesPerBall
        for trail = 1, 3 do
            local point = visual.History[trail]
            quad(renderer, firstVertex + (trail - 1) * 6, point.X, point.Y,
                renderer.Radius * (0.85 - trail * 0.15), 0.16 - trail * 0.035)
        end
        quad(renderer, firstVertex + 18, visual.X, visual.Y, renderer.Radius, 1)
    end
    -- Clear vacated slots, including after the stats panel temporarily hid the mesh.
    for vertex = count * verticesPerBall, (renderer.previousCount or 0) * verticesPerBall - 1 do
        renderer.colors[vertex * 4 + 4] = 0
    end
    -- The serialized mesh owns the resource; this Lua staging buffer is copied
    -- and reused. Capacity follows active load with hysteresis, independently
    -- of the GUI node budget, so old peaks do not tax every future frame.
    resource.set_buffer(renderer.Resource, renderer.data)
    renderer.previousCount, renderer.DrawnCount = count, count
    renderer.dirty = false
end

function BallRenderer.Dispose(renderer)
    if renderer.disposed then return end
    renderer.disposed = true
    local disabled, disableError = pcall(msg.post, renderer.Mesh, "disable")
    local cleared, clearError = pcall(function()
        if renderer.Capacity == 0 then return end
        reserve(renderer, 0)
        for vertex = 0, (renderer.previousCount or 0) * verticesPerBall - 1 do
            renderer.colors[vertex * 4 + 4] = 0
        end
        resource.set_buffer(renderer.Resource, renderer.data)
    end)
    renderer.active, renderer.free = {}, {}
    renderer.data, renderer.positions, renderer.uvs, renderer.colors = nil, nil, nil, nil
    renderer.Capacity, renderer.DrawnCount = 0, 0
    local errors = {}
    if not disabled then errors[#errors + 1] = tostring(disableError) end
    if not cleared then errors[#errors + 1] = tostring(clearError) end
    if #errors > 0 then error(table.concat(errors, "\n"), 0) end
end

return BallRenderer
