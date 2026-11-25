package.path = "./lib/?.lua;./tests/unit/?.lua;" .. package.path
local stubs = require("stubs")
local loader = require("loader")

local function eq(a, b, label)
    if a ~= b then
        error((label or "eq") .. ": expected " .. tostring(b) ..
            ", got " .. tostring(a), 2)
    end
end

local real_getenv = os.getenv
local cwd = "/work/proj"
local envrc = cwd .. "/.envrc"
local configured = "/opt/direnv/bin/direnv"
local path_env = "/usr/bin"
local cached_json = '{"cached":true}'
local config_json = '[{"path":"/cfg/mise.toml"}]'
local config_text = '[env]\n_.envrc = { direnv_bin = "' .. configured .. '" }\n'
local cached = {
    cwd = cwd,
    envrc = envrc,
    env = {},
    paths = {},
    warnings = {},
    watch_files = { envrc },
    key = loader.result_key(cwd, envrc, {
        direnv_bin = configured, timeout = 30, state_dir = nil, dotenv = false,
    }, path_env),
}

local commands = {}
stubs.cmd.exec = function(c)
    commands[#commands + 1] = c
    if c == "pwd -P" then return cwd .. "\n" end
    if c:find("config --json", 1, true) then return config_json end
    if c:find("'direnv' version", 1, true) then
        error("bare direnv must not be probed")
    end
    return ""
end
stubs.json.decode = function(s)
    if s == "null" then return stubs.NULL end
    if s == config_json then return { { path = "/cfg/mise.toml" } } end
    if s == cached_json then return cached end
    error("unexpected decode: " .. tostring(s))
end
stubs.file.read = function(p)
    if p:find("result-", 1, true) then return cached_json end
    if p == "/cfg/mise.toml" then return config_text end
    error("unexpected read: " .. tostring(p))
end
stubs.file.stat = function() return nil end
stubs.file.glob = function() return {} end
stubs.file.exists = function() return false end
stubs.log.warn = function() end

os.getenv = function(k)
    if k == "PATH" then return path_env end
    if k == "HOME" then return "/home/u" end
    return nil
end

-- An empty sibling declaration must validate the hand-off cache using the
-- configured binary rather than falling back to bare `direnv`.
local result = loader.load_cached({ options = {} })
eq(result, cached, "cached result reused with effective direnv_bin")
for _, c in ipairs(commands) do
    if c:find("'direnv' version", 1, true) then
        error("bare direnv was probed: " .. c)
    end
end
local saw_config_lookup = false
for _, c in ipairs(commands) do
    if c:find("config --json", 1, true) then saw_config_lookup = true end
end
eq(saw_config_lookup, true, "sibling declaration consulted config files")

-- An explicit directive option needs no lookup and produces the same key.
commands = {}
stubs.cmd.exec = function(c)
    commands[#commands + 1] = c
    if c == "pwd -P" then return cwd .. "\n" end
    if c:find("config --json", 1, true) then
        error("explicit direnv_bin should not consult config files")
    end
    return ""
end
eq(loader.load_cached({ options = { direnv_bin = configured } }), cached,
    "explicit direnv_bin cache hit")

-- An explicit bare `direnv` is not an omitted option: it must not reuse a
-- cache entry produced with a configured sibling binary.
commands = {}
stubs.cmd.exec = function(c)
    commands[#commands + 1] = c
    if c == "pwd -P" then return cwd .. "\n" end
    if c:find("config --json", 1, true) then
        error("explicit bare direnv should not consult config files")
    end
    return ""
end
local bare_result = loader.load_cached({ options = { direnv_bin = "direnv" } })
if bare_result == cached then
    error("explicit bare direnv reused a configured-binary cache entry")
end
eq(bare_result.envrc, nil, "explicit bare direnv recomputes with defaults")
for _, c in ipairs(commands) do
    if c:find("'direnv' version", 1, true) then
        error("unexpected bare direnv probe: " .. c)
    end
end

os.getenv = real_getenv
print("test_loader_direnv_bin: ok")
