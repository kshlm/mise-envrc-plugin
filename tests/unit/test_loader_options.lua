package.path = "./lib/?.lua;./tests/unit/?.lua;" .. package.path
local stubs = require("stubs")
local loader = require("loader")
local mise = require("mise")
local direnv = require("direnv")

local function eq(a, b, label)
    if a ~= b then
        error((label or "eq") .. ": expected " .. tostring(b) ..
            ", got " .. tostring(a), 2)
    end
end

local real_getenv = os.getenv
local real_is_trusted = mise.is_trusted
local cwd = "/work/proj"
local envrc = cwd .. "/.envrc"
local configured = "/cfg/direnv"
local explicit = "/explicit/direnv"
local env_override = "/env/direnv"
local path_env = "/usr/bin"
local config_json = '[{"path":"/cfg/mise.toml"}]'
local config_text = '[env]\n_.envrc = { direnv_bin = "' .. configured .. '" }\n'

local commands, warnings = {}, {}
local env_vars = {}
local envrc_exists = true
local config_skip = false
local trust_fn = function() return true, "" end

os.getenv = function(k) return env_vars[k] end
mise.is_trusted = function(...) return trust_fn(...) end
mise.remember_direnv_bin = function() end
direnv.build_config = function() return "/tmp/gen" end
direnv.export = function() return {}, "" end

stubs.cmd.exec = function(c)
    commands[#commands + 1] = c
    if c == "pwd -P" then return cwd .. "\n" end
    if c:find("config --json", 1, true) then return config_json end
    return ""
end
stubs.json.decode = function(s)
    if s == "null" then return stubs.NULL end
    if s == config_json then return { { path = "/cfg/mise.toml" } } end
    error("unexpected decode: " .. tostring(s))
end
stubs.file.read = function(p)
    if p == "/cfg/mise.toml" then return config_text end
    error("unexpected read: " .. tostring(p))
end
stubs.file.stat = function(p)
    if envrc_exists and p == envrc then
        return { is_file = true, modified = 1 }
    end
    return nil
end
stubs.file.exists = function() return false end
stubs.file.glob = function()
    if config_skip then return { cwd .. "/mise.toml" } end
    return {}
end
stubs.log.warn = function(msg) warnings[#warnings + 1] = msg end
stubs.log.debug = function() end

local function reset(opts)
    opts = opts or {}
    commands, warnings = {}, {}
    envrc_exists = opts.envrc ~= false
    config_skip = opts.config == true
    env_vars = { PATH = path_env, HOME = "/home/u" }
    if opts.env_bin then env_vars.MISE_ENVRC_DIRENV_BIN = opts.env_bin end
    trust_fn = opts.trust or function() return true, "" end
end

local function has_command(fragment)
    for _, c in ipairs(commands) do
        if c:find(fragment, 1, true) then return true end
    end
    return false
end

local function version_commands()
    local out = {}
    for _, c in ipairs(commands) do
        if c:find(" version", 1, true) then out[#out + 1] = c end
    end
    return out
end

-- An omitted option inherits the configured sibling binary.
reset({})
loader.load({ options = {} }, false)
local versions = version_commands()
eq(#versions, 1, "omitted option probes one binary")
if not versions[1]:find(configured, 1, true) then
    error("omitted option did not inherit sibling direnv_bin: " .. versions[1])
end
eq(has_command("config --json"), true, "omitted option consults config files")
eq(has_command("config get"), false, "no per-file config-get subprocess")

-- An explicit absolute path wins over both the environment and sibling config.
reset({ env_bin = env_override })
loader.load({ options = { direnv_bin = explicit } }, false)
versions = version_commands()
eq(#versions, 1, "explicit path probes one binary")
if not versions[1]:find(explicit, 1, true) then
    error("explicit path was overridden: " .. versions[1])
end
eq(has_command("config --json"), false, "explicit path skips config lookup")

-- An explicit bare `direnv` is a deliberate choice, not an omitted option.
reset({ env_bin = env_override })
loader.load({ options = { direnv_bin = "direnv" } }, false)
versions = version_commands()
eq(#versions, 1, "explicit bare name probes one binary")
if not versions[1]:find("'direnv' version", 1, true) then
    error("explicit bare name did not probe direnv: " .. versions[1])
end
if versions[1]:find(configured, 1, true) or
    versions[1]:find(env_override, 1, true) then
    error("explicit bare name inherited another binary: " .. versions[1])
end
eq(has_command("config --json"), false, "explicit bare name skips config lookup")

-- Trust comes before config lookups and binary execution.
reset({
    env_bin = env_override,
    trust = function() return false, "not trusted" end,
})
local untrusted = loader.load({ options = {} }, false)
eq(has_command("config --json"), false, "untrusted project skips config lookup")
eq(has_command(" version"), false, "untrusted project skips direnv probe")
eq(#untrusted.warnings, 1, "untrusted project has one warning")
if not untrusted.warnings[1]:find("not trusted", 1, true) then
    error("missing trust warning: " .. tostring(untrusted.warnings[1]))
end
eq(#warnings, 1, "trust warning emitted once")
if not warnings[1]:find("not trusted", 1, true) then
    error("emitted warning is not the trust warning: " .. warnings[1])
end

-- No `.envrc` or a winning mise config must not probe or look up anything.
reset({
    env_bin = env_override,
    envrc = false,
    trust = function() error("trust checked without an .envrc") end,
})
loader.load({ options = {} }, false)
eq(#commands, 1, "absent .envrc runs only pwd")
eq(commands[1], "pwd -P", "absent .envrc command")
eq(has_command(" version"), false, "absent .envrc skips direnv probe")

reset({
    env_bin = env_override,
    config = true,
    trust = function() error("trust checked when mise config wins") end,
})
loader.load({ options = {} }, false)
eq(#commands, 1, "mise-config skip runs only pwd")
eq(commands[1], "pwd -P", "mise-config skip command")
eq(has_command("config --json"), false, "mise-config skip avoids config lookup")
eq(has_command(" version"), false, "mise-config skip avoids direnv probe")

-- force = true overrides the mise-config skip and loads anyway.
reset({ env_bin = env_override, config = true })
local forced = loader.load({ options = { force = true } }, false)
eq(has_command(" version"), true, "force probes direnv despite mise config")
eq(forced.envrc, envrc, "force loads the envrc")

-- The cache key changes when force flips, so cached results don't leak across modes.
local plain = loader.result_key(cwd, envrc, { direnv_bin = "d", timeout = 30, dotenv = false, force = false }, path_env)
local forced_key = loader.result_key(cwd, envrc, { direnv_bin = "d", timeout = 30, dotenv = false, force = true }, path_env)
if plain == forced_key then error("force option missing from cache key") end

os.getenv = real_getenv
mise.is_trusted = real_is_trusted
print("test_loader_options: ok")
