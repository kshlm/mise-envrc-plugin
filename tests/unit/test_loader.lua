package.path = "./lib/?.lua;./tests/unit/?.lua;" .. package.path
local stubs = require("stubs")
local util = require("util")
local loader = require("loader")

local function eq(a, b, label)
    if a ~= b then error((label or "eq") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

local opts = { direnv_bin = "direnv", timeout = 30, state_dir = nil, dotenv = false }
local k1 = loader.result_key("/work/proj", "/work/proj/.envrc", opts, "/usr/bin")
local k2 = loader.result_key("/work/proj", "/work/proj/.envrc", opts, "/usr/bin")
eq(k1, k2, "cache key stable")
local k3 = loader.result_key("/work/proj", "/work/proj/.envrc", opts, "/usr/bin:/extra")
if k1 == k3 then error("cache key ignores PATH") end

local emitted = {}
stubs.log.warn = function(msg) emitted[#emitted + 1] = msg end
local result = util.map_diff({
    FOO = "bar", GONE = stubs.NULL, PATH = "/old:/base:/tail",
}, "/old:/base", function(v) return v == stubs.NULL end,
    { env = {}, paths = {}, warnings = {} })
eq(#result.env, 1, "env count")
eq(#result.warnings, 1, "one combined warning")
if not result.warnings[1]:find("unset GONE", 1, true) then error("missing unset detail") end
if not result.warnings[1]:find("PATH change", 1, true) then error("missing PATH detail") end
loader.emit(result)
eq(#emitted, 1, "emit count")

-- guard: MISE_ENVRC_PLUGIN=1 must short-circuit without running direnv
local real_getenv = os.getenv
os.getenv = function(k) if k == "MISE_ENVRC_PLUGIN" then return "1" end return nil end
stubs.cmd.exec = function() error("must not run a command") end
local guarded = loader.load({ options = {} }, false)
eq(#guarded.env, 0, "guard env empty")
eq(#guarded.paths, 0, "guard paths empty")
os.getenv = real_getenv

print("test_loader: ok")
