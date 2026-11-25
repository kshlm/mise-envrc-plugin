local util = require("util")
local file = require("file")
local cmd = require("cmd")
local json = require("json")

local M = {}

local USER_BIN_ENV = "MISE_ENVRC_DIRENV_BIN"
local PROCESS_BIN_ENV = "__MISE_ENVRC_DIRENV_BIN"

local function env_value(name)
    local v = os.getenv(name)
    if type(v) ~= "string" then return nil end
    v = util.trim(v)
    if v == "" then return nil end
    return v
end

local function guard_env()
    local out = { MISE_NO_ENV = "1", MISE_ENVRC_PLUGIN = "1" }
    for _, key in ipairs({
        "HOME", "XDG_CONFIG_HOME", "MISE_CONFIG_DIR",
        "MISE_GLOBAL_CONFIG_FILE", "MISE_SYSTEM_CONFIG_FILE",
        "MISE_OVERRIDE_CONFIG_FILE", "MISE_ENV",
    }) do
        local v = os.getenv(key)
        if v then out[key] = v end
    end
    return out
end

-- `mise config get --file ...` exists in supported mise releases, but using it
-- here would need one subprocess per config file and a resolvable `mise` on
-- PATH. A cold-start hook can have that directory removed along with direnv,
-- so keep a narrow scanner as the single lookup path rather than maintaining
-- both a CLI path and a fallback parser.
local BASIC_ESCAPES = {
    b = "\b", t = "\t", n = "\n", f = "\f", r = "\r",
    ['"'] = '"', ["\\"] = "\\",
}

local function strip_comment(line)
    local quote, escaped = nil, false
    for i = 1, #line do
        local c = line:sub(i, i)
        if quote == '"' and escaped then
            escaped = false
        elseif quote == '"' and c == "\\" then
            escaped = true
        elseif quote then
            if c == quote then quote = nil end
        elseif c == '"' or c == "'" then
            quote = c
        elseif c == "#" then
            return line:sub(1, i - 1)
        end
    end
    return line
end

local function unescape_basic(s)
    local out, i = {}, 1
    while i <= #s do
        local c = s:sub(i, i)
        if c == "\\" and i < #s then
            local n = s:sub(i + 1, i + 1)
            local replacement = BASIC_ESCAPES[n]
            if not replacement then return nil end
            out[#out + 1] = replacement
            i = i + 2
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

local function scalar(rest)
    local v = util.trim(rest or "")
    local q = v:sub(1, 1)
    if q ~= '"' and q ~= "'" then return nil end
    local escaped = false
    for i = 2, #v do
        local c = v:sub(i, i)
        if q == '"' and escaped then
            escaped = false
        elseif q == '"' and c == "\\" then
            escaped = true
        elseif c == q then
            local inner = v:sub(2, i - 1)
            if q == '"' then return unescape_basic(inner) end
            return inner
        end
    end
    return nil
end

local function direnv_bin_value(line)
    local rest = line:match("direnv_bin%s*=%s*(.+)$")
    if not rest then return nil end
    return scalar(rest)
end

local function is_envrc_section(section)
    return section == "env._.envrc" or section == 'env."_.envrc"'
        or section == "env.'_.envrc'"
end

local function starts_envrc_table(line, section)
    if section == "env" then
        return line:match("^_%.envrc%s*=") ~= nil or
            line:match('^"_.envrc"%s*=') ~= nil or
            line:match("^'_.envrc'%s*=") ~= nil
    end
    if section == nil then
        return line:match("^env%._%.envrc%s*=") ~= nil or
            line:match('^env%."_.envrc"%s*=') ~= nil
    end
    if section == "env._" then
        return line:match("^envrc%s*=") ~= nil
    end
    return false
end

-- Only exact `_.envrc` dotted-key spellings are accepted; a broad substring
-- match could mistake an unrelated `envrc_*`/`direnv_bin` key for the plugin.
local function is_dotted_envrc_key(line, section)
    local key = line:match("^([^%s=]+)%s*=")
    if not key then return false end
    if section == nil then
        return key == "env._.envrc.direnv_bin" or
            key == 'env."_.envrc".direnv_bin' or
            key == "env.'_.envrc'.direnv_bin"
    end
    if section == "env" then
        return key == "_.envrc.direnv_bin" or
            key == '"_.envrc".direnv_bin' or
            key == "'_.envrc'.direnv_bin"
    end
    if section == "env._" then
        return key == "envrc.direnv_bin"
    end
    return false
end

-- Read just `direnv_bin` from the common TOML spellings of the directive.
-- This is intentionally a scanner, not a TOML parser: config files are only
-- consulted to make an explicitly configured binary available to a sibling
-- `_.envrc` declaration that mise invoked without options.
local function direnv_bin_from_text(text)
    local section, in_inline, found = nil, false, nil
    for raw in tostring(text):gmatch("[^\n]+") do
        local line = util.trim(strip_comment(raw))
        if line ~= "" then
            local header = line:match("^%[%s*([^%]]+)%s*%]$")
            if header then
                section = (header:gsub("%s", ""))
                in_inline = false
            else
                local mentions = line:find("direnv_bin", 1, true) ~= nil
                if starts_envrc_table(line, section) then
                    local v = direnv_bin_value(line)
                    if v then found = v end
                    if line:find("{", 1, true) and not line:find("}", 1, true) then
                        in_inline = true
                    end
                elseif in_inline then
                    if mentions then
                        local v = direnv_bin_value(line)
                        if v then found = v end
                    end
                    if line:find("}", 1, true) then in_inline = false end
                elseif is_envrc_section(section) and
                    line:match("^direnv_bin%s*=") then
                    local v = direnv_bin_value(line)
                    if v then found = v end
                elseif is_dotted_envrc_key(line, section) then
                    local v = direnv_bin_value(line)
                    if v then found = v end
                end
            end
        end
    end
    return found
end

local function add_config_path(paths, p)
    if type(p) == "string" and p:lower():match("%.toml$") then
        paths[#paths + 1] = p
    end
end

local function fallback_config_paths()
    local paths = {}
    local config_dir = env_value("MISE_CONFIG_DIR")
    if not config_dir then
        config_dir = util.join(os.getenv("HOME") or "", ".config/mise")
    end
    add_config_path(paths, os.getenv("MISE_SYSTEM_CONFIG_FILE"))
    add_config_path(paths, env_value("MISE_GLOBAL_CONFIG_FILE") or
        util.join(config_dir, "config.toml"))
    local okglob, matches = pcall(file.glob,
        util.join(config_dir, "conf.d/*.toml"))
    if okglob and type(matches) == "table" then
        for _, p in ipairs(matches) do add_config_path(paths, p) end
    end
    add_config_path(paths, env_value("MISE_OVERRIDE_CONFIG_FILE"))
    return paths
end

local function config_paths()
    local paths = {}
    local ok, raw = pcall(cmd.exec, "mise --no-env config --json", {
        env = guard_env(), timeout = 5,
    })
    if ok then
        local okjson, parsed = pcall(json.decode, raw)
        if okjson and type(parsed) == "table" then
            if type(parsed.config_files) == "table" then
                parsed = parsed.config_files
            end
            for _, entry in ipairs(parsed) do
                local p = nil
                if type(entry) == "string" then
                    p = entry
                elseif type(entry) == "table" and type(entry.path) == "string" then
                    p = entry.path
                end
                add_config_path(paths, p)
            end
        end
    end
    if #paths == 0 then return fallback_config_paths() end
    return paths
end

-- Share a working binary with the other `.envrc` directive invocations in the
-- same mise process. The user-facing variable always takes precedence.
function M.remember_direnv_bin(bin)
    if type(bin) ~= "string" then return end
    local v = util.trim(bin)
    if v == "" or v == "direnv" or env_value(USER_BIN_ENV) then return end
    local envmod = package.loaded["env"]
    if not envmod then
        local ok, loaded = pcall(require, "env")
        if ok then envmod = loaded end
    end
    if type(envmod) == "table" and type(envmod.setenv) == "function" then
        pcall(envmod.setenv, PROCESS_BIN_ENV, v)
    end
end

-- mise calls an environment plugin once per `_.envrc` declaration and passes
-- only that declaration's options. Find an explicitly configured binary from
-- any loaded declaration so a sibling empty declaration does not fall back to
-- a bare `direnv` that is deliberately absent from PATH.
function M.direnv_bin()
    local override = env_value(USER_BIN_ENV)
    if override then return override end
    local remembered = env_value(PROCESS_BIN_ENV)
    if remembered then return remembered end

    -- `mise config --json` lists files from lowest to highest precedence.
    local paths = config_paths()
    for i = #paths, 1, -1 do
        local ok, text = pcall(file.read, paths[i])
        if ok then
            local okparse, bin = pcall(direnv_bin_from_text, text)
            if okparse and type(bin) == "string" and bin ~= "" then
                M.remember_direnv_bin(bin)
                return bin
            end
        end
    end
    return nil
end

function M.settings()
    local out = { trusted_config_paths = {}, ignored_config_paths = {}, paranoid = false }
    local ok, raw = pcall(cmd.exec, "mise --no-env settings --all --json", {
        env = { MISE_NO_ENV = "1", MISE_ENVRC_PLUGIN = "1" },
        timeout = 10,
    })
    if not ok then return out end
    local okjson, parsed = pcall(json.decode, raw)
    if not okjson or type(parsed) ~= "table" then return out end
    if type(parsed.trusted_config_paths) == "table" then
        out.trusted_config_paths = parsed.trusted_config_paths
    end
    if type(parsed.ignored_config_paths) == "table" then
        out.ignored_config_paths = parsed.ignored_config_paths
    end
    out.paranoid = parsed.paranoid == true
    return out
end

function M.state_dir(opts)
    if opts.state_dir and opts.state_dir ~= "" then return opts.state_dir end
    local d = os.getenv("MISE_STATE_DIR")
    if d and d ~= "" then return d end
    local x = os.getenv("XDG_STATE_HOME")
    if x and x ~= "" then return util.join(x, "mise") end
    return util.join(os.getenv("HOME") or "", ".local/state/mise")
end

function M.records(dir)
    local result = { trusted = {}, ignored = {}, hashes = {} }
    local kinds = { { "trusted-configs", "trusted" }, { "ignored-configs", "ignored" } }
    for _, kind in ipairs(kinds) do
        local d = util.join(dir, kind[1])
        local command = [[for f in ]] .. util.sh_quote(d) ..
            [[/*; do [ -L "$f" ] && printf '%s\t%s\n' "$f" "$(readlink "$f")"; done]]
        local ok, out = pcall(cmd.exec, command, { timeout = 10 })
        if ok then
            for line in tostring(out):gmatch("[^\n]+") do
                local link, target = line:match("^([^\t]+)\t(.+)$")
                if link and target then
                    local list = result[kind[2]]
                    list[#list + 1] = target
                    if kind[2] == "trusted" then
                        local okh, digest = pcall(file.read, link .. ".hash")
                        if okh then result.hashes[target] = util.trim(digest) end
                    end
                end
            end
        end
    end
    return result
end

local function matches_any(path, list, home)
    for _, p in ipairs(list or {}) do
        if util.path_prefix(util.expand_home(p, home), path) then return true end
    end
    return false
end

function M.is_trusted(project_dir, envrc, opts)
    local settings = M.settings()
    local records = M.records(M.state_dir(opts))
    local home = os.getenv("HOME") or ""

    if matches_any(project_dir, settings.ignored_config_paths, home) then
        return false, "ignored by settings"
    end
    for _, p in ipairs(records.ignored) do
        if util.path_prefix(p, project_dir) then return false, "ignored by mise" end
    end

    if settings.paranoid then
        local expected = records.hashes[envrc]
        if not expected then
            return false, "paranoid mode requires an approved .envrc"
        end
        local tool = (util.runtime_field("osType") == "darwin")
            and "shasum -a 256 " or "sha256sum "
        local ok, out = pcall(cmd.exec, tool .. util.sh_quote(envrc), { timeout = 10 })
        if not ok then return false, "could not hash .envrc" end
        local got = tostring(out):match("^(%x+)")
        if not got or got ~= expected then
            return false, ".envrc changed since it was trusted"
        end
        return true, ""
    end

    if matches_any(project_dir, settings.trusted_config_paths, home) then
        return true, ""
    end
    for _, p in ipairs(records.trusted) do
        if util.path_prefix(p, project_dir) or p == envrc then return true, "" end
    end
    return false, "not trusted"
end

return M
