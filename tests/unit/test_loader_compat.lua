package.path = "./lib/?.lua;./tests/unit/?.lua;" .. package.path
local stubs = require("stubs")
local util = require("util")
local loader = require("loader")

local function eq(a, b, label)
    if a ~= b then error((label or "eq") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

-- Mimic mise's strict mlua RUNTIME userdata: accessing a field mise did not
-- register raises instead of returning nil (mise < 2026.10.17 has no
-- cacheDirPath, so RUNTIME.cacheDirPath must not be touched unguarded).
local function strict_runtime(fields)
    return setmetatable(fields or {}, {
        __index = function(_, k)
            error("attempt to get an unknown field '" .. tostring(k) .. "'", 2)
        end,
    })
end

-- util.runtime_field: safe read of a strict RUNTIME field
eq(util.runtime_field and true or false, true, "util.runtime_field exists")
local sentinel = strict_runtime({ osType = "darwin" })
_G.RUNTIME = sentinel
eq(util.runtime_field("osType"), "darwin", "strict present field")
eq(util.runtime_field("cacheDirPath"), nil, "strict missing field -> nil")
eq(util.runtime_field("anythingElse"), nil, "strict other missing field -> nil")
_G.RUNTIME = { osType = "linux" }
eq(util.runtime_field("osType"), "linux", "plain table field")
_G.RUNTIME = nil
eq(util.runtime_field("osType"), nil, "nil RUNTIME -> nil")

local tmp = "/tmp/mise-envrc-compat-test"
local real_getenv = os.getenv

-- mise 2026.10.3 on macOS: strict RUNTIME without cacheDirPath; the plugin
-- must fall back to MISE_CACHE_DIR instead of crashing the MisePath hook.
local executed = {}
_G.RUNTIME = strict_runtime({ osType = "darwin" })
os.getenv = function(k) if k == "MISE_CACHE_DIR" then return tmp end return nil end
stubs.cmd.exec = function(c) executed[#executed + 1] = tostring(c) return "" end
stubs.file.stat = function() return nil end
stubs.file.read = function() error("enoent") end
local okres, res = pcall(loader.load_cached, { options = {} })
eq(okres, true, "load_cached survives strict RUNTIME without cacheDirPath")
eq(type(res), "table", "load_cached returns a result")
eq(#res.env, 0, "no env without a .envrc")
local fell_back = false
for _, c in ipairs(executed) do
    if c:find("mkdir -p", 1, true) and c:find(tmp, 1, true) then fell_back = true end
end
eq(fell_back, true, "cache root falls back to MISE_CACHE_DIR")

-- mise >= 2026.10.17: RUNTIME provides cacheDirPath; it wins and no fallback
-- directory is created.
executed = {}
_G.RUNTIME = strict_runtime({ osType = "darwin", cacheDirPath = "/run/mise-plugin-cache" })
okres, res = pcall(loader.load_cached, { options = {} })
eq(okres, true, "load_cached survives strict RUNTIME with cacheDirPath")
local used_fallback = false
for _, c in ipairs(executed) do
    if c:find(tmp, 1, true) then used_fallback = true end
end
eq(used_fallback, false, "runtime cacheDirPath wins over MISE_CACHE_DIR")

-- RUNTIME entirely absent must not crash either.
executed = {}
_G.RUNTIME = nil
okres, res = pcall(loader.load_cached, { options = {} })
eq(okres, true, "load_cached survives RUNTIME == nil")
eq(type(res), "table", "load_cached returns a result without RUNTIME")

os.getenv = real_getenv
_G.RUNTIME = { osType = "linux", cacheDirPath = "/tmp/mise-envrc-test-cache" }
print("test_loader_compat: ok")
