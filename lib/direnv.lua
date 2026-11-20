local util = require("util")
local file = require("file")
local cmd = require("cmd")
local json = require("json")

local M = {}
local VERSION = "1"

local function write(path, content)
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
end

local function real_config_dir()
    local d = os.getenv("DIRENV_CONFIG")
    if d and d ~= "" then return d end
    local x = os.getenv("XDG_CONFIG_HOME")
    if x and x ~= "" then return util.join(x, "direnv") end
    return util.join(os.getenv("HOME") or "", ".config/direnv")
end

local function global_scalars(path)
    local ok, text = pcall(file.read, path)
    if not ok then return {} end
    local out, section = {}, nil
    for line in tostring(text):gmatch("[^\n]+") do
        local header = line:match("^%s*%[([%w_]+)%]%s*$")
        if header then
            section = header
        elseif section == nil or section == "global" then
            local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
            if key and key ~= "log_format" and key ~= "hide_env_diff"
                and value ~= "" and not value:match("^[%[{]") then
                out[#out + 1] = line
            end
        end
    end
    return out
end

function M.build_config(envrc, cache_dir)
    local gen = util.join(util.join(cache_dir, "direnv"), util.hash(envrc))
    local lib = util.join(gen, "lib")
    cmd.exec("mkdir -p " .. util.sh_quote(lib))

    -- Always rewrite the whitelist: a hash collision must never leave a stale
    -- approval for a different .envrc.
    local toml = {
        "[whitelist]",
        "exact = [" .. json.encode(envrc) .. "]",
        "",
        "[global]",
        "hide_env_diff = true",
        'log_format = ""',
    }
    local real = real_config_dir()
    for _, name in ipairs({ "direnv.toml", "config.toml" }) do
        local extras = global_scalars(util.join(real, name))
        if #extras > 0 then
            for _, line in ipairs(extras) do toml[#toml + 1] = line end
            break
        end
    end
    write(util.join(gen, "direnv.toml"), table.concat(toml, "\n") .. "\n")

    local version_path = util.join(gen, "version")
    local current = nil
    local okv, v = pcall(file.read, version_path)
    if okv then current = util.trim(v) end
    if current ~= VERSION then
        cmd.exec("rm -f " .. util.sh_quote(util.join(gen, "direnvrc")) ..
            " " .. util.sh_quote(lib) .. "/*.sh")

        local rc = { "use_mise() { :; }" }
        local home = os.getenv("HOME") or ""
        local candidates = { util.join(real, "direnvrc"), util.join(home, ".direnvrc") }
        for _, p in ipairs(candidates) do
            if file.exists(p) then rc[#rc + 1] = "source " .. util.sh_quote(p) end
        end
        write(util.join(gen, "direnvrc"), table.concat(rc, "\n") .. "\n")

        local okg, libs = pcall(file.glob, util.join(real, "lib", "*.sh"))
        if okg then
            for _, src in ipairs(libs) do
                local okr, content = pcall(file.read, src)
                if okr and not content:find("mise direnv", 1, true) then
                    local dst = util.join(lib, util.basename(src))
                    if not file.stat(dst) then pcall(file.symlink, src, dst) end
                end
            end
        end
        write(version_path, VERSION)
    end
    return gen
end

function M.export(gen, cwd, opts)
    local stderr_path = util.join(gen, "stderr")
    local command = util.sh_quote(opts.direnv_bin) ..
        " export json 2> " .. util.sh_quote(stderr_path)
    local env = {
        DIRENV_CONFIG = gen,
        DIRENV_LOG_FORMAT = "",
        MISE_ENVRC_PLUGIN = "1",
        DIRENV_DIFF = "",
        DIRENV_DIR = "",
        DIRENV_FILE = "",
        DIRENV_WATCHES = "",
        DIRENV_IN_ENVRC = "",
        DIRENV_DISABLE = "",
    }
    local ok, out = pcall(cmd.exec, command,
        { cwd = cwd, env = env, timeout = opts.timeout })
    if not ok then return nil, tostring(out) end

    local okerr, stderr = pcall(file.read, stderr_path)
    local err = okerr and util.trim(stderr) or ""
    local trimmed = util.trim(out)
    if trimmed == "" then return {}, err end
    local okjson, diff = pcall(json.decode, trimmed)
    if not okjson or type(diff) ~= "table" then
        return nil, "invalid direnv JSON: " .. tostring(diff)
    end
    return diff, err
end

return M
