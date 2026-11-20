local util = require("util")
local mise = require("mise")
local direnv = require("direnv")
local file = require("file")
local cmd = require("cmd")
local json = require("json")
local log = require("log")

local M = {}
local GUARD = "MISE_ENVRC_PLUGIN"
local NULL = json.decode("null")
local NUL = string.char(0)

local function empty()
    return { env = {}, paths = {}, warnings = {}, watch_files = {}, envrc = nil }
end

local function options(raw)
    local o = { direnv_bin = "direnv", timeout = 30, state_dir = nil, dotenv = false }
    if type(raw) == "table" then
        if type(raw.direnv_bin) == "string" then o.direnv_bin = raw.direnv_bin end
        if type(raw.timeout) == "number" and raw.timeout > 0 then o.timeout = raw.timeout end
        if type(raw.state_dir) == "string" then o.state_dir = raw.state_dir end
        if raw.dotenv == true then o.dotenv = true end
    else
        log.debug("mise-envrc: directive should be a table")
    end
    return o
end

local function warn(result, msg)
    result.warnings[#result.warnings + 1] = msg
end

local function current_cwd()
    local ok, out = pcall(cmd.exec, "pwd -P")
    if not ok then return nil end
    return util.trim(out)
end

local function cache_path(cwd)
    local cache = RUNTIME and RUNTIME.cacheDirPath
    if not cache or not cwd then return nil end
    return util.join(cache, "result-" .. util.hash(cwd) .. ".json")
end

function M.result_key(cwd, envrc, opts, path_env)
    local info = file.stat(envrc)
    local mtime = info and tostring(info.modified) or "0"
    local o = table.concat({
        opts.direnv_bin, tostring(opts.timeout), opts.state_dir or "",
        tostring(opts.dotenv),
    }, NUL)
    return util.hash(table.concat({ cwd, envrc, mtime, o, path_env or "" }, NUL))
end

function M.emit(result)
    for _, msg in ipairs(result.warnings or {}) do log.warn(msg) end
end

function M.load(ctx, quiet)
    local result = empty()
    if os.getenv(GUARD) == "1" then return result end
    local safe = os.getenv("MISE_SAFE")
    if safe == "1" or safe == "true" then return result end

    local opts = options(ctx.options)
    local okver = pcall(cmd.exec,
        util.sh_quote(opts.direnv_bin) .. " version", { timeout = 5 })
    if not okver then
        if not quiet then
            log.warn("mise-envrc: direnv not found; install direnv to load .envrc files")
        end
        return result
    end

    local cwd = current_cwd()
    if not cwd then return result end
    local names = { ".envrc" }
    if opts.dotenv then names[#names + 1] = ".env" end
    local envrc = util.find_up(cwd, names, function(p) return file.stat(p) end)
    if not envrc then return result end

    local project_dir = util.dir_of(envrc)
    local dirs = util.ancestors(cwd, project_dir)
    local has_cfg, where = util.has_mise_config(dirs,
        function(p) return file.glob(p) end,
        function(p) return file.exists(p) end)
    if has_cfg then
        log.debug("mise-envrc: skipping, mise config found in " .. tostring(where))
        return result
    end

    local trusted, reason = mise.is_trusted(project_dir, envrc, opts)
    if not trusted then
        warn(result, "mise-envrc: " .. envrc .. " is not trusted by mise (" ..
            tostring(reason) .. "); run 'mise trust " .. project_dir .. "' to load it")
        if not quiet then M.emit(result) end
        return result
    end

    local cache = RUNTIME and RUNTIME.cacheDirPath
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
                local expected = M.result_key(cwd, cached.envrc, opts,
                    os.getenv("PATH") or "")
                if cached.key == expected then return cached end
            end
        end
    end
    return M.load(ctx, true)
end

return M
