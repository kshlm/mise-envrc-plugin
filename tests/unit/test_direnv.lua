package.path = "./lib/?.lua;./tests/unit/?.lua;" .. package.path
local stubs = require("stubs")
local util = require("util")
local direnv = require("direnv")

local function eq(a, b, label)
    if a ~= b then error((label or "eq") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

local captured = {}
stubs.cmd.exec = function(command, options)
    captured[#captured + 1] = { command = command, options = options }
    if command:find("export json", 1, true) then
        return '{"FOO":"bar","GONE":null,"PATH":"/new:/old","DIRENV_DIFF":"x"}'
    end
    return ""
end
stubs.json.decode = function(s)
    if s == "null" then return stubs.NULL end
    if not s:find("FOO") then error("unexpected decode") end
    return { FOO = "bar", GONE = stubs.NULL, PATH = "/new:/old", DIRENV_DIFF = "x" }
end
stubs.file.read = function(p)
    if p:match("stderr$") then return "" end
    error("file.read stub")
end

local diff, err = direnv.export("/tmp/gen", "/work/proj",
    { direnv_bin = "direnv", timeout = 30 })
eq(type(diff), "table", "export returns diff")
eq(diff.FOO, "bar", "export diff value")
eq(err, "", "export stderr empty")
eq(captured[#captured].options.env.DIRENV_CONFIG, "/tmp/gen", "DIRENV_CONFIG set")
eq(captured[#captured].options.env.MISE_ENVRC_PLUGIN, "1", "guard set")
eq(captured[#captured].options.env.DIRENV_DIFF, "", "direnv state blanked")
eq(captured[#captured].options.cwd, "/work/proj", "cwd set")
eq(captured[#captured].options.timeout, 30, "timeout set")
if not captured[#captured].command:find("2> '/tmp/gen/stderr'", 1, true) then
    error("stderr redirect missing")
end

print("test_direnv: ok")
