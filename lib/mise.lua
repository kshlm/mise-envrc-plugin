local util = require("util")
local file = require("file")
local cmd = require("cmd")
local json = require("json")

local M = {}

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
        local tool = (RUNTIME and RUNTIME.osType == "darwin")
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
