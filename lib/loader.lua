local util = require("util")
local mise = require("mise")
local direnv = require("direnv")
local file = require("file")
local cmd = require("cmd")
local json = require("json")
local log = require("log")

local M = {}
local GUARD = "MISE_ENVRC_PLUGIN"
local DEFAULT_BIN = "direnv"
local USER_BIN_ENV = "MISE_ENVRC_DIRENV_BIN"
local PROCESS_BIN_ENV = "__MISE_ENVRC_DIRENV_BIN"
local NULL = json.decode("null")
local NUL = string.char(0)

local function empty()
    return { env = {}, paths = {}, warnings = {}, watch_files = {}, envrc = nil }
end

local function options(raw)
    local o = { direnv_bin = DEFAULT_BIN, direnv_bin_explicit = false,
        timeout = 30, state_dir = nil, dotenv = false, force = false }
    if type(raw) == "table" then
        if type(raw.direnv_bin) == "string" then
            o.direnv_bin_explicit = true
            if raw.direnv_bin ~= "" then o.direnv_bin = raw.direnv_bin end
        end
        if type(raw.timeout) == "number" and raw.timeout > 0 then o.timeout = raw.timeout end
        if type(raw.state_dir) == "string" then o.state_dir = raw.state_dir end
        if raw.dotenv == true then o.dotenv = true end
        if raw.force == true then o.force = true end
    else
        log.debug("mise-envrc: directive should be a table")
    end
    return o
end

local function env_value(name)
    local v = os.getenv(name)
    if type(v) ~= "string" then return nil end
    v = util.trim(v)
    if v == "" then return nil end
    return v
end

-- A directive without `direnv_bin` still has to see a binary configured by a
-- sibling `_.envrc` declaration: mise invokes the hooks once per declaration
-- and supplies only that file's options.
local function resolve_direnv_bin(opts)
    if opts.direnv_bin_explicit then return end
    local override = env_value(USER_BIN_ENV)
    if override then
        opts.direnv_bin = override
        return
    end
    local remembered = env_value(PROCESS_BIN_ENV)
    if remembered then
        opts.direnv_bin = remembered
        return
    end
    local ok, configured = pcall(mise.direnv_bin)
    if ok and type(configured) == "string" and configured ~= "" then
        opts.direnv_bin = configured
    end
end

local function warn(result, msg)
    result.warnings[#result.warnings + 1] = msg
end

local function current_cwd()
    local ok, out = pcall(cmd.exec, "pwd -P")
    if not ok then return nil end
    return util.trim(out)
end

-- Resolve the plugin's cache root. Prefer mise's per-plugin cacheDirPath
-- (mise >= 2026.10.17); on older mise fall back to a user-owned directory so
-- the plugin still works. Returns nil when no usable directory exists.
local function cache_root()
    local root = util.runtime_field("cacheDirPath")
    if not root or root == "" then
        local base = os.getenv("MISE_CACHE_DIR")
        if base and base ~= "" then
            root = util.join(base, "envrc-plugin")
        else
            local xdg = os.getenv("XDG_CACHE_HOME")
            if xdg and xdg ~= "" then
                root = util.join(util.join(xdg, "mise"), "envrc-plugin")
            else
                local home = os.getenv("HOME")
                if not home or home == "" then return nil end
                root = util.join(util.join(home, ".cache/mise"), "envrc-plugin")
            end
        end
    end
    local okstat, info = pcall(file.stat, root)
    if okstat and info and info.is_dir then return root end
    local okmkdir = pcall(cmd.exec, "mkdir -p " .. util.sh_quote(root))
    if not okmkdir then return nil end
    return root
end

local function cache_path(cwd)
    local cache = cache_root()
    if not cache or not cwd then return nil end
    return util.join(cache, "result-" .. util.hash(cwd) .. ".json")
end

function M.result_key(cwd, envrc, opts, path_env)
    local info = file.stat(envrc)
    local mtime = info and tostring(info.modified) or "0"
    local o = table.concat({
        opts.direnv_bin, tostring(opts.timeout), opts.state_dir or "",
        tostring(opts.dotenv == true), tostring(opts.force == true),
    }, NUL)
    return util.hash(table.concat({ cwd, envrc, mtime, o, path_env or "" }, NUL))
end

function M.emit(result)
    for _, msg in ipairs(result.warnings or {}) do log.warn(msg) end
end

function M.load(ctx, quiet)
    local result = empty()
    if os.getenv(GUARD) == "1" then
        log.debug("mise-envrc: not loading, recursive invocation guarded by " .. GUARD)
        return result
    end
    local safe = os.getenv("MISE_SAFE")
    if safe == "1" or safe == "true" then
        log.debug("mise-envrc: not loading, MISE_SAFE is set")
        return result
    end

    local opts = options(ctx.options)
    local cwd = current_cwd()
    if not cwd then
        log.debug("mise-envrc: not loading, could not determine working directory")
        return result
    end
    local names = { ".envrc" }
    if opts.dotenv then names[#names + 1] = ".env" end
    local envrc = util.find_up(cwd, names, function(p) return file.stat(p) end)
    if not envrc then
        log.debug("mise-envrc: not loading, no " .. table.concat(names, " or ") ..
            " found in " .. cwd .. " or any parent")
        return result
    end
    log.debug("mise-envrc: found " .. envrc)

    local project_dir = util.dir_of(envrc)
    local dirs = util.ancestors(cwd, project_dir)
    local has_cfg, where = util.has_mise_config(dirs,
        function(p) return file.glob(p) end,
        function(p) return file.exists(p) end)
    if has_cfg then
        if not opts.force then
            log.debug("mise-envrc: skipping, mise config found in " .. tostring(where))
            return result
        end
        log.debug("mise-envrc: forcing load despite mise config in " .. tostring(where))
    end

    -- Trust comes first: an untrusted project should receive the actionable
    -- trust warning without config lookups or direnv execution, even when
    -- direnv is missing from PATH.
    local trusted, reason = mise.is_trusted(project_dir, envrc, opts)
    if not trusted then
        warn(result, "mise-envrc: " .. envrc .. " is not trusted by mise (" ..
            tostring(reason) .. "); run 'mise trust " .. project_dir .. "' to load it")
        if not quiet then M.emit(result) end
        return result
    end

    -- Check the binary only once an `.envrc` would actually be loaded. A
    -- duplicate, optionless directive must stay silent when mise config or an
    -- absent `.envrc` makes this invocation a no-op.
    resolve_direnv_bin(opts)
    log.debug("mise-envrc: using direnv binary " .. opts.direnv_bin)
    local okver = pcall(cmd.exec,
        util.sh_quote(opts.direnv_bin) .. " version", { timeout = 5 })
    if not okver then
        if not quiet then
            log.warn("mise-envrc: direnv not found; install direnv, set " ..
                "direnv_bin on the _.envrc directive, or set " .. USER_BIN_ENV)
        end
        return result
    end
    pcall(mise.remember_direnv_bin, opts.direnv_bin)

    local cache = cache_root()
    if not cache then
        warn(result, "mise-envrc: mise did not provide a plugin cache directory")
        if not quiet then M.emit(result) end
        return result
    end

    local okbuild, gen = pcall(direnv.build_config, envrc, cache)
    if not okbuild then
        warn(result, "mise-envrc: could not build direnv config: " .. tostring(gen))
        if not quiet then M.emit(result) end
        return result
    end

    local diff, err = direnv.export(gen, cwd, opts)
    if err and err ~= "" and
        (err:find("error", 1, true) or err:find("blocked", 1, true)) then
        warn(result, "mise-envrc: direnv: " .. (err:match("[^\n]+") or err))
    end
    if not diff then
        log.debug("mise-envrc: not loading, direnv produced no environment diff")
        if not quiet then M.emit(result) end
        return result
    end

    local path_env = os.getenv("PATH") or ""
    util.map_diff(diff, path_env, function(v) return v == NULL end, result)
    result.envrc = envrc
    result.cwd = cwd
    result.watch_files = { envrc }
    result.key = M.result_key(cwd, envrc, opts, path_env)

    local cp = cache_path(cwd)
    if cp then
        local tmp = cp .. ".tmp"
        local okw, f = pcall(io.open, tmp, "w")
        if okw and f then
            pcall(function() f:write(json.encode(result)); f:close() end)
            pcall(file.move, tmp, cp)
        end
    end
    if not quiet then M.emit(result) end
    log.debug("mise-envrc: loaded " .. #result.env .. " env vars and " ..
        #result.paths .. " path entries from " .. envrc)
    return result
end

function M.load_cached(ctx)
    local cwd = current_cwd()
    if not cwd then return empty() end
    local cp = cache_path(cwd)
    if cp then
        local ok, raw = pcall(file.read, cp)
        if ok then
            local okjson, cached = pcall(json.decode, raw)
            if okjson and type(cached) == "table" and cached.cwd == cwd
                and cached.envrc then
                local opts = options(ctx.options)
                local path_env = os.getenv("PATH") or ""
                local expected = M.result_key(cwd, cached.envrc, opts, path_env)
                if cached.key ~= expected then
                    -- The stored key embeds the resolved direnv binary. A
                    -- sibling declaration may have configured it; retry with
                    -- the effective options before recomputing.
                    resolve_direnv_bin(opts)
                    expected = M.result_key(cwd, cached.envrc, opts, path_env)
                end
                if cached.key == expected then return cached end
                log.debug("mise-envrc: cache entry stale, reloading")
            end
        end
    end
    log.debug("mise-envrc: no usable cache entry, reloading")
    return M.load(ctx, true)
end

return M
