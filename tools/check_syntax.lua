-- Compile source chunks only. Never invoke the returned functions: this tool
-- does not execute gameplay, Defold callbacks, or test specifications.
local failures = 0
for index, path in ipairs(arg) do
    local chunk, parseError = loadfile(path)
    if not chunk then
        failures = failures + 1
        io.stderr:write(path, ": ", tostring(parseError), "\n")
    end
end
if failures > 0 then
    io.stderr:write(tostring(failures), " Lua syntax error(s)\n")
    os.exit(1)
end
io.write("Lua syntax OK: ", #arg, " source files. No chunks executed.\n")
