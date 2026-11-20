local M = {}

-- mise exposes RUNTIME as a strict userdata: reading a field it does not
-- register raises instead of returning nil (e.g. cacheDirPath was only added
-- in mise 2026.10.17). Route all RUNTIME field reads through here.
function M.runtime_field(name)
    if not RUNTIME then return nil end
    local ok, v = pcall(function() return RUNTIME[name] end)
    if not ok then return nil end
    return v
end

function M.sh_quote(s)
    local q = string.char(39)
    local b = string.char(92)
    return q .. tostring(s):gsub(q, q .. b .. q .. q) .. q
end

function M.trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.split(s, sep)
    local out = {}
    for part in tostring(s or ""):gmatch("([^" .. sep .. "]+)") do
        out[#out + 1] = part
    end
    return out
end

function M.dir_of(path)
    if path == "/" then return "/" end
    local parent = path:match("^(.*)/[^/]+$")
    if not parent or parent == "" then return "/" end
    return parent
end

function M.basename(path)
    return path:match("[^/]+$") or path
end

function M.join(...)
    local n = select("#", ...)
    local out = select(1, ...) or ""
    for i = 2, n do
        local b = select(i, ...)
        if b and b ~= "" then
            if out:sub(-1) == "/" then out = out .. b else out = out .. "/" .. b end
        end
    end
    return out
end

function M.ancestors(start, stop)
    local dirs, cur, seen = {}, start, {}
    while true do
        dirs[#dirs + 1] = cur
        if cur == stop or cur == "/" or seen[cur] then break end
        seen[cur] = true
        local parent = M.dir_of(cur)
        if parent == cur then break end
        cur = parent
    end
    return dirs
end

function M.path_prefix(prefix, dir)
    if not prefix or prefix == "" then return false end
    if prefix == "/" then return true end
    if prefix:sub(-1) == "/" then prefix = prefix:sub(1, -2) end
    if dir == prefix then return true end
    return dir:sub(1, #prefix + 1) == prefix .. "/"
end

function M.expand_home(p, home)
    if p == "~" then return home end
    if p:sub(1, 2) == "~/" then return M.join(home, p:sub(3)) end
    return p
end

function M.hash(s)
    local h1, h2, MOD = 5381, 52711, 2147483648
    for i = 1, #s do
        local b = s:byte(i)
        h1 = (h1 * 33 + b) % MOD
        h2 = (h2 * 65599 + b) % MOD
    end
    return string.format("%08x%08x%08x", h1, h2, #s)
end

function M.sorted_keys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

function M.find_up(cwd, names, stat)
    local dir = cwd
    while true do
        for _, name in ipairs(names) do
            local p = M.join(dir, name)
            local info = stat(p)
            if info and info.is_file then return p, dir end
        end
        if dir == "/" then return nil end
        local parent = M.dir_of(dir)
        if parent == dir then return nil end
        dir = parent
    end
end

local MISE_PATTERNS = {
    "mise*.toml", ".mise*.toml",
    "mise/*.toml", "mise/conf.d/*.toml", "mise/conf.d/*/mise*.toml",
    ".mise/*.toml", ".mise/conf.d/*.toml",
    ".config/mise*.toml", ".config/mise/*.toml", ".config/mise/conf.d/*.toml",
}
M.MISE_PATTERNS = MISE_PATTERNS

function M.has_mise_config(dirs, glob, exists)
    for _, dir in ipairs(dirs) do
        if exists(M.join(dir, ".tool-versions")) then return true, dir end
        for _, pat in ipairs(MISE_PATTERNS) do
            local ok, matches = pcall(glob, M.join(dir, pat))
            if ok and matches and #matches > 0 then return true, dir end
        end
    end
    return false
end

function M.path_prepends(old, new)
    if new == old then return {}, false end
    if old == "" then return nil, true end
    local suffix = ":" .. old
    if new:sub(-#suffix) ~= suffix then return nil, true end
    local prefix = new:sub(1, #new - #suffix)
    if prefix == "" then return {}, false end
    return M.split(prefix, ":"), false
end

function M.map_diff(diff, old_path, is_null, result)
    result = result or { env = {}, paths = {}, warnings = {} }
    result.env = result.env or {}
    result.paths = result.paths or {}
    result.warnings = result.warnings or {}
    local unsupported = {}
    for _, k in ipairs(M.sorted_keys(diff)) do
        local v = diff[k]
        if k:match("^DIRENV_") or k:match("^__MISE_") or k == "MISE_ENVRC_PLUGIN" then
            -- internal: never exported
        elseif is_null(v) then
            unsupported[#unsupported + 1] = "unset " .. k
        elseif k == "PATH" then
            if type(v) == "string" then
                local prepends, bad = M.path_prepends(old_path, v)
                if bad then
                    unsupported[#unsupported + 1] = "PATH change"
                else
                    for _, p in ipairs(prepends) do result.paths[#result.paths + 1] = p end
                end
            else
                unsupported[#unsupported + 1] = "PATH change"
            end
        elseif type(v) == "string" then
            result.env[#result.env + 1] = { key = k, value = v }
        else
            unsupported[#unsupported + 1] = "non-string " .. k
        end
    end
    if #unsupported > 0 then
        result.warnings[#result.warnings + 1] =
            "uses operations mise cannot express (" .. table.concat(unsupported, ", ") ..
            "); they were ignored"
    end
    return result
end

return M
