package.path = "./lib/?.lua;./tests/unit/?.lua;" .. package.path
local stubs = require("stubs")
local mise = require("mise")

local function eq(a, b, label)
    if a ~= b then
        error((label or "eq") .. ": expected " .. tostring(b) ..
            ", got " .. tostring(a), 2)
    end
end

local real_getenv = os.getenv
local real_envmod = package.loaded["env"]
local function set_env(values)
    os.getenv = function(k) return values[k] end
end

-- A user-level environment override wins without consulting config files.
local commands = {}
stubs.cmd.exec = function(c)
    commands[#commands + 1] = c
    return ""
end
set_env({ MISE_ENVRC_DIRENV_BIN = "  /override/direnv  " })
eq(mise.direnv_bin(), "/override/direnv", "environment override")
eq(#commands, 0, "environment override skips config lookup")

-- `mise config --json` lists files from lowest to highest precedence. The
-- highest-precedence declaration with direnv_bin wins.
local config_json = '[{"path":"/cfg/low.toml"},{"path":"/cfg/high.toml"}]'
local files = {
    ["/cfg/low.toml"] = '[env]\n_.envrc = { direnv_bin = "/low/direnv" }\n',
    ["/cfg/high.toml"] = '[env._.envrc]\ndirenv_bin = "/high/direnv" # comment\n',
}
local read_paths = {}
local saved_env = {}
package.loaded["env"] = {
    setenv = function(k, v) saved_env[k] = v end,
}
stubs.cmd.exec = function(c)
    if c:find("config --json", 1, true) then return config_json end
    error("unexpected command: " .. tostring(c))
end
stubs.json.decode = function(s)
    if s == "null" then return stubs.NULL end
    if s == config_json then
        return { { path = "/cfg/low.toml" }, { path = "/cfg/high.toml" } }
    end
    error("unexpected decode: " .. tostring(s))
end
stubs.file.read = function(p)
    read_paths[#read_paths + 1] = p
    if files[p] then return files[p] end
    error("unexpected read: " .. tostring(p))
end
set_env({})
eq(mise.direnv_bin(), "/high/direnv", "highest-precedence direnv_bin")
eq(#read_paths, 1, "only highest-precedence file read")
eq(read_paths[1], "/cfg/high.toml", "highest-precedence file")
eq(saved_env.__MISE_ENVRC_DIRENV_BIN, "/high/direnv",
    "configured binary shared with sibling hooks")

-- Common TOML spellings of the directive must all resolve.
local function direnv_bin_from(text)
    local path = "/cfg/test.toml"
    local list = '["' .. path .. '"]'
    stubs.cmd.exec = function(c)
        if c:find("config --json", 1, true) then return list end
        error("unexpected command: " .. tostring(c))
    end
    stubs.json.decode = function(s)
        if s == "null" then return stubs.NULL end
        if s == list then return { path } end
        error("unexpected decode: " .. tostring(s))
    end
    stubs.file.read = function(p)
        if p == path then return text end
        error("unexpected read: " .. tostring(p))
    end
    return mise.direnv_bin()
end

eq(direnv_bin_from(
    '[env]\n"_.envrc" = { direnv_bin = "/inline/direnv", timeout = 30 }\n'),
    "/inline/direnv", "inline table")
eq(direnv_bin_from(
    '[env]\n_.envrc = {\n  direnv_bin = "/multi/direnv",\n}\n'),
    "/multi/direnv", "multi-line inline table")
eq(direnv_bin_from(
    '[env]\n_.envrc.direnv_bin = "/dotted/direnv"\n'),
    "/dotted/direnv", "dotted key")
eq(direnv_bin_from(
    '[env._.envrc]\n# direnv_bin = "/comment/direnv"\ndirenv_bin = "/section/direnv"\n'),
    "/section/direnv", "section table ignores comments")
eq(direnv_bin_from(
    '[env._]\nenvrc = { direnv_bin = "/nested/direnv" }\n'),
    "/nested/direnv", "nested env table")
eq(direnv_bin_from(
    'env._.envrc.direnv_bin = "/top-dotted/direnv"\n'),
    "/top-dotted/direnv", "top-level dotted key")
eq(direnv_bin_from(
    '[env]\n"_.envrc".direnv_bin = "/quoted-dotted/direnv"\n'),
    "/quoted-dotted/direnv", "quoted dotted key")

-- Escaped quotes and comments inside strings must not truncate the value.
eq(direnv_bin_from([=[
[env._.envrc]
direnv_bin = "/escaped/\"quote # not a comment/direnv" # real comment
]=]), '/escaped/"quote # not a comment/direnv',
    "escaped quote and comment inside basic string")
eq(direnv_bin_from([=[
[env._.envrc]
direnv_bin = '/literal/#not-comment/direnv' # real comment
]=]), "/literal/#not-comment/direnv",
    "hash inside literal string")
eq(direnv_bin_from([=[
[env._.envrc]
direnv_bin = "/escaped/backslash\\direnv" # real comment
]=]), "/escaped/backslash\\direnv",
    "escaped backslash inside basic string")
eq(direnv_bin_from([=[
[env._.envrc]
direnv_bin = "/unsupported/\qescape"
]=]), nil, "unsupported escape is not guessed")

-- Narrow matching must not pick up similarly named keys from other tables.
eq(direnv_bin_from([=[
[env]
NOT_.envrc.direnv_bin = "/wrong"
_.envrc_other.direnv_bin = "/wrong"
_.other = { direnv_bin = "/wrong" }
"envrc".direnv_bin = "/wrong"

[settings]
envrc_direnv_bin = "/wrong"

[env._.envrc]
# direnv_bin = "/comment/direnv"
]=]), nil, "unrelated lookalike keys ignored")

os.getenv = real_getenv
package.loaded["env"] = real_envmod
print("test_mise_options: ok")
