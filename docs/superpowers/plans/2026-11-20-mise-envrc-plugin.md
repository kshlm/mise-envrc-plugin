# mise-envrc-plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a mise environment plugin that loads the nearest `.envrc` into mise's environment for projects with no mise config, gated by mise's own trust store.

**Architecture:** A Lua environment plugin (`[env] _.envrc = {}` in the global mise config) whose two hooks (`MiseEnv`, `MisePath`) share a loader. The loader discovers an rc file, skips directories with any mise config, checks mise trust records/settings, builds a generated `DIRENV_CONFIG` with a `[whitelist]` for that one file, runs `direnv export json`, and maps the diff into env vars plus prepended PATH entries. A small on-disk hand-off cache avoids running direnv twice per env build.

**Tech Stack:** Lua 5.1 (mise's embedded vfox Lua runtime), mise ≥ 2026.10.17 environment-plugin API, direnv ≥ 2.34.0 CLI, POSIX bash, `jq` and `lua` for tests.

## Global Constraints

- Plugin name **and** directive suffix: exactly `envrc` (`[env] _.envrc = { }`).
- Minimums: mise with `MiseEnv`/`MisePath` hooks (verified 2026.10.17); direnv ≥ 2.34.0 (verified 2.38.2).
- Linux/macOS only; Windows is unsupported.
- No direnv shell hook, no `direnv allow`, no changes to third-party repos.
- mise's trust store is the only approval mechanism; deny-wins precedence.
- `unset`, PATH append/reorder/removal: warn once and ignore; never fail the hook.
- No error path may raise `Lua error()` and break every mise command in a directory.
- Every interpolated path in a shell command must be single-quote escaped.
- `ctx.config_root` is never used for project paths (it resolves to `$HOME` for the global config).
- `cacheable = false` on `MiseEnv`; `watch_files = { <envrc> }`.
- Directive options: `direnv_bin` (string, `"direnv"`), `timeout` (number, `30`), `state_dir` (string, unset), `dotenv` (boolean, `false`). `tools` and `redact` belong to mise.
- All Lua code must be Lua 5.1 compatible (no `goto`, no `table.unpack`, no `//`).
- Error messages must never contain environment variable values.

---

## File structure

| File | Responsibility |
| --- | --- |
| `metadata.lua` | Plugin identity (`PLUGIN` table) |
| `hooks/mise_env.lua` | `MiseEnv` hook: returns env vars + cache metadata |
| `hooks/mise_path.lua` | `MisePath` hook: returns prepended PATH directories |
| `lib/util.lua` | Pure helpers: quoting, paths, hashing, matching, diff mapping |
| `lib/mise.lua` | mise settings + trust-record reading + trust decision |
| `lib/direnv.lua` | Generated direnv config, `direnv export json`, diff decode |
| `lib/loader.lua` | Orchestration, warnings, hand-off cache |
| `tests/unit/stubs.lua` | Stub mise Lua modules for plain-Lua unit tests |
| `tests/unit/test_util.lua` | Pure-helper tests |
| `tests/unit/test_trust.lua` | Trust-decision tests |
| `tests/unit/test_loader.lua` | Diff mapping + cache-key tests |
| `tests/e2e.sh` | End-to-end tests against real mise + direnv |
| `README.md` | Install, trust workflow, options, limitations |
| `LICENSE` | MIT |

---

### Task 1: Scaffold and verify the mise plugin toolchain

**Files:**
- Create: `metadata.lua`, `hooks/mise_env.lua`, `hooks/mise_path.lua`, `tests/smoke.sh`
- Create later: `lib/*.lua` (Tasks 2–5)

**Interfaces:**
- Consumes: nothing.
- Produces: `PLUGIN` table with `name = "envrc"`; hook methods `PLUGIN:MiseEnv(ctx)` and `PLUGIN:MisePath(ctx)`.

- [ ] **Step 1: Write failing smoke test**

```bash
#!/usr/bin/env bash
# tests/smoke.sh — verifies mise can load this plugin and run both hooks.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
S=$(mktemp -d "${TMPDIR:-/tmp}/mise-envrc-smoke.XXXXXX")
trap 'rm -rf "$S"' EXIT
mkdir -p "$S/config" "$S/data" "$S/state" "$S/cache" "$S/work"
export MISE_CONFIG_DIR="$S/config" MISE_DATA_DIR="$S/data" \
       MISE_STATE_DIR="$S/state" MISE_CACHE_DIR="$S/cache"
printf '[env]\n_.envrc = { }\n' > "$S/config/config.toml"
mise plugins link envrc "$ROOT" >/dev/null
out=$(cd "$S/work" && mise env --json)
echo "$out" | jq -e '.SMOKE_OK == "yes"' >/dev/null
first=$(echo "$out" | jq -r '.PATH | split(":")[0]')
[ "$first" = "$S/work/bin" ]
echo "smoke: ok"
```

- [ ] **Step 2: Run the smoke test to verify it fails**

Run: `bash tests/smoke.sh`
Expected: FAIL (`jq` cannot find `.SMOKE_OK`) because no plugin files exist yet.

- [ ] **Step 3: Write the minimal plugin files**

`metadata.lua`:

```lua
PLUGIN = {
    name = "envrc",
    version = "0.1.0",
    description = "Load .envrc files for projects that have no mise config",
    license = "MIT",
}
```

`hooks/mise_env.lua` (temporary stub, replaced in Task 6):

```lua
function PLUGIN:MiseEnv(ctx)
    return { env = { { key = "SMOKE_OK", value = "yes" } }, cacheable = false }
end
```

`hooks/mise_path.lua` (temporary stub, replaced in Task 6):

```lua
local util = require("util")
function PLUGIN:MisePath(ctx)
    return { util.join(os.getenv("PWD") or "", "bin") }
end
```

`lib/util.lua` (minimal; expanded in Task 2):

```lua
local M = {}
function M.join(a, b)
    if a:sub(-1) == "/" then return a .. b end
    return a .. "/" .. b
end
return M
```

- [ ] **Step 4: Run the smoke test to verify it passes**

Run: `bash tests/smoke.sh`
Expected: `smoke: ok`

- [ ] **Step 5: Commit**

```bash
git add metadata.lua hooks lib tests/smoke.sh
git commit -m "feat: scaffold mise envrc plugin and smoke-test the hook toolchain"
```

---

### Task 2: `lib/util.lua` pure helpers

**Files:**
- Modify: `lib/util.lua`
- Create: `tests/unit/stubs.lua`, `tests/unit/test_util.lua`

**Interfaces:**
- Consumes: nothing.
- Produces (all `local util = require("util")`):
  - `util.sh_quote(s) -> string`
  - `util.trim(s) -> string`
  - `util.split(s, sep) -> string[]` (empty fields dropped)
  - `util.dir_of(path) -> string`
  - `util.basename(path) -> string`
  - `util.join(a, b) -> string`
  - `util.ancestors(start, stop) -> string[]` (start … stop inclusive, stops at `/`)
  - `util.path_prefix(prefix, dir) -> boolean`
  - `util.expand_home(p, home) -> string`
  - `util.hash(s) -> string` (24 lowercase hex chars: two hashes + length)
  - `util.sorted_keys(t) -> string[]`
  - `util.find_up(cwd, names, stat) -> (string|nil, string|nil)` where `stat(path) -> info|nil`, `info.is_file`
  - `util.has_mise_config(dirs, glob, exists) -> (boolean, string|nil)` where `glob(pattern) -> string[]`, `exists(path) -> boolean`, second return is the matching dir
  - `util.path_prepends(old, new) -> (string[]|nil, boolean)` — second value true means unsupported change
  - `util.map_diff(diff, old_path, is_null, result) -> result` — `is_null(v)` predicate; fills `result.env`, `result.paths`, `result.warnings`

- [ ] **Step 1: Write the failing unit test**

`tests/unit/stubs.lua`:

```lua
local NULL = {}
local stubs = {
    NULL = NULL,
    file = {
        stat = function() return nil end,
        exists = function() return false end,
        glob = function() return {} end,
        read = function() error("file.read stub") end,
        symlink = function() end,
        move = function() end,
    },
    cmd = { exec = function() return "" end },
    json = {
        decode = function(s)
            if s == "null" then return NULL end
            error("json.decode stub only handles null")
        end,
        encode = function(v) return tostring(v) end,
    },
    log = {
        debug = function() end, info = function() end,
        warn = function() end, error = function() end,
    },
}
package.loaded["file"] = stubs.file
package.loaded["cmd"] = stubs.cmd
package.loaded["json"] = stubs.json
package.loaded["log"] = stubs.log
_G.RUNTIME = { osType = "linux", cacheDirPath = "/tmp/mise-envrc-test-cache" }
return stubs
```

`tests/unit/test_util.lua`:

```lua
package.path = "./lib/?.lua;./tests/unit/?.lua;" .. package.path
local stubs = require("stubs")
local util = require("util")

local function eq(a, b, label)
    if a ~= b then error((label or "eq") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

eq(util.sh_quote("/a'b"), "'/a'\\''b'", "sh_quote")
eq(util.trim("  x\n"), "x", "trim")
eq(util.dir_of("/a/b/.envrc"), "/a/b", "dir_of")
eq(util.dir_of("/a"), "/", "dir_of root parent")
eq(util.basename("/a/b/.envrc"), ".envrc", "basename")
eq(util.join("/a", ".envrc"), "/a/.envrc", "join")
eq(util.path_prefix("/a/b", "/a/b"), true, "prefix exact")
eq(util.path_prefix("/a/b", "/a/bc"), false, "prefix boundary")
eq(util.path_prefix("/a/b", "/a/b/c"), true, "prefix child")
eq(util.expand_home("~/src", "/home/u"), "/home/u/src", "expand_home")
eq(#util.hash("/a/b"), 24, "hash length")
eq(util.hash("/a/b"), util.hash("/a/b"), "hash stable")
if util.hash("/a/b") == util.hash("/a/c") then error("hash collision") end

local dirs = util.ancestors("/a/b/c", "/a")
eq(table.concat(dirs, ","), "/a/b/c,/a/b,/a", "ancestors")
eq(util.join(util.split("a:b::c", ":")[1], ""), "a/", "split")

local found = util.find_up("/a/b/c", { ".envrc" }, function(p)
    return p == "/a/.envrc" and { is_file = true } or nil
end)
eq(found, "/a/.envrc", "find_up")

local seen = {}
local has = util.has_mise_config({ "/a/b" },
    function(p) seen[#seen + 1] = p; return {} end,
    function() return false end)
eq(has, false, "no mise config")
eq(#seen, 10, "glob pattern count")
local has2, where2 = util.has_mise_config({ "/a/b" },
    function() return {} end,
    function(p) return p == "/a/b/.tool-versions" end)
eq(has2, true, "tool-versions detected")
eq(where2, "/a/b", "tool-versions dir")
local has3 = util.has_mise_config({ "/a/b" },
    function(p) return p == "/a/b/mise*.toml" and { "/a/b/mise.toml" } or {} end,
    function() return false end)
eq(has3, true, "mise.toml glob detected")

local adds, bad = util.path_prepends("/old:/base", "/new1:/new2:/old:/base")
eq(bad, false, "prepends supported")
eq(table.concat(adds, ","), "/new1,/new2", "prepends value")
local _, bad2 = util.path_prepends("/old:/base", "/old:/base:/appended")
eq(bad2, true, "append unsupported")

local result = util.map_diff({
    FOO = "bar",
    GONE = stubs.NULL,
    DIRENV_DIFF = "internal",
    MISE_ENVRC_PLUGIN = "1",
    PATH = "/new:/old:/base",
}, "/old:/base", function(v) return v == stubs.NULL end,
    { env = {}, paths = {}, warnings = {} })
eq(#result.env, 1, "map_diff env count")
eq(result.env[1].key, "FOO", "map_diff key")
eq(result.paths[1], "/new", "map_diff path")
eq(#result.warnings, 1, "map_diff warning count")
if not result.warnings[1]:find("unset GONE", 1, true) then error("missing unset warning") end

print("test_util: ok")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `lua tests/unit/test_util.lua`
Expected: FAIL with `attempt to call field 'sh_quote' (a nil value)`.

- [ ] **Step 3: Implement `lib/util.lua`**

```lua
local M = {}

function M.sh_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
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

function M.join(a, b)
    if a:sub(-1) == "/" then return a .. b end
    return a .. "/" .. b
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `lua tests/unit/test_util.lua`
Expected: `test_util: ok`

- [ ] **Step 5: Also re-run the smoke test**

Run: `bash tests/smoke.sh`
Expected: `smoke: ok`

- [ ] **Step 6: Commit**

```bash
git add lib/util.lua tests/unit tests/smoke.sh
git commit -m "feat: add pure path, trust-match and env-diff helpers"
```

---

### Task 3: `lib/mise.lua` — settings, trust records, trust decision

**Files:**
- Create: `lib/mise.lua`, `tests/unit/test_trust.lua`

**Interfaces:**
- Consumes: `util.sh_quote`, `util.join`, `util.trim`, `util.path_prefix`, `util.expand_home`.
- Produces (`local mise = require("mise")`):
  - `mise.settings() -> { trusted_config_paths = string[], ignored_config_paths = string[], paranoid = boolean }`
  - `mise.state_dir(opts) -> string`
  - `mise.records(dir) -> { trusted = string[], ignored = string[], hashes = { [path]=string } }`
  - `mise.is_trusted(project_dir, envrc, opts) -> (boolean, string)` — second value is the reason when false.

- [ ] **Step 1: Write the failing unit test**

`tests/unit/test_trust.lua`:

```lua
package.path = "./lib/?.lua;./tests/unit/?.lua;" .. package.path
local stubs = require("stubs")
local mise = require("mise")

local function eq(a, b, label)
    if a ~= b then error((label or "eq") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

local settings = {
    trusted_config_paths = {}, ignored_config_paths = {}, paranoid = false,
}
local records = { trusted = {}, ignored = {}, hashes = {} }
mise.settings = function() return settings end
mise.records = function() return records end

local opts = {}
local ok, reason = mise.is_trusted("/work/proj", "/work/proj/.envrc", opts)
eq(ok, false, "untrusted default")
eq(reason, "not trusted", "untrusted reason")

records.trusted = { "/work/proj" }
ok = mise.is_trusted("/work/proj/sub", "/work/proj/sub/.envrc", opts)
eq(ok, true, "directory trust covers child")
records.trusted = {}

settings.trusted_config_paths = { "~/work" }
os.getenv = function(k) if k == "HOME" then return "/home/u" end return nil end
ok = mise.is_trusted("/home/u/work/proj", "/home/u/work/proj/.envrc", opts)
eq(ok, true, "trusted_config_paths with tilde")
settings.trusted_config_paths = {}

settings.ignored_config_paths = { "/work" }
records.trusted = { "/work/proj" }
ok, reason = mise.is_trusted("/work/proj", "/work/proj/.envrc", opts)
eq(ok, false, "ignore overrides trust")
eq(reason, "ignored by settings", "ignore reason")
settings.ignored_config_paths = {}
records.trusted = {}

settings.paranoid = true
records.hashes = {}
ok, reason = mise.is_trusted("/work/proj", "/work/proj/.envrc", opts)
eq(ok, false, "paranoid needs hash")
if not tostring(reason):find("approved", 1, true) then error("paranoid reason") end

records.hashes["/work/proj/.envrc"] = "deadbeef"
stubs.cmd.exec = function() return "cafebabe  /work/proj/.envrc\n" end
ok, reason = mise.is_trusted("/work/proj", "/work/proj/.envrc", opts)
eq(ok, false, "paranoid hash mismatch")
if not tostring(reason):find("changed", 1, true) then error("paranoid mismatch reason") end

records.hashes["/work/proj/.envrc"] = "cafebabe"
ok = mise.is_trusted("/work/proj", "/work/proj/.envrc", opts)
eq(ok, true, "paranoid hash match")

print("test_trust: ok")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `lua tests/unit/test_trust.lua`
Expected: FAIL (`attempt to index local 'mise' (a boolean value)` — no `lib/mise.lua` yet).

- [ ] **Step 3: Implement `lib/mise.lua`**

```lua
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
        local command = "for f in " .. util.sh_quote(d) ..
            "/*; do [ -L \"$f\" ] && printf '%s\\t%s\\n' \"$f\" \"$(readlink \"$f\")\"; done"
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `lua tests/unit/test_trust.lua`
Expected: `test_trust: ok`

- [ ] **Step 5: Commit**

```bash
git add lib/mise.lua tests/unit/test_trust.lua
git commit -m "feat: gate .envrc loading on mise trust records and settings"
```

---

### Task 4: `lib/direnv.lua` — generated config and `direnv export json`

**Files:**
- Create: `lib/direnv.lua`, `tests/unit/test_direnv.lua`

**Interfaces:**
- Consumes: `util.sh_quote`, `util.join`, `util.basename`, `util.hash`, `util.trim`.
- Produces (`local direnv = require("direnv")`):
  - `direnv.build_config(envrc, cache_dir) -> string` (generated `DIRENV_CONFIG` path)
  - `direnv.export(gen, cwd, opts) -> (table|nil, string)` — diff table (or `{}` for no rc), and captured stderr text; `nil` means failure.

- [ ] **Step 1: Write the failing unit test**

`tests/unit/test_direnv.lua`:

```lua
package.path = "./lib/?.lua;./tests/unit/?.lua;" .. package.path
local stubs = require("stubs")
local util = require("util")
local direnv = require("direnv")

local function eq(a, b, label)
    if a ~= b then error((label or "eq") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

local captured = {}
stubs.cmd.exec = function(command, options)
    captured[#captured + 1] = { command = command, options = options }
    if command:find("export json", 1, true) then
        return '{"FOO":"bar","GONE":null,"PATH":"/new:/old","DIRENV_DIFF":"x"}'
    end
    return ""
end
stubs.json.decode = function(s)
    if s == "null" then return stubs.NULL end
    if not s:find("FOO") then error("unexpected decode") end
    return { FOO = "bar", GONE = stubs.NULL, PATH = "/new:/old", DIRENV_DIFF = "x" }
end
stubs.file.read = function(p)
    if p:match("stderr$") then return "" end
    error("file.read stub")
end

local diff, err = direnv.export("/tmp/gen", "/work/proj",
    { direnv_bin = "direnv", timeout = 30 })
eq(type(diff), "table", "export returns diff")
eq(diff.FOO, "bar", "export diff value")
eq(err, "", "export stderr empty")
eq(captured[#captured].options.env.DIRENV_CONFIG, "/tmp/gen", "DIRENV_CONFIG set")
eq(captured[#captured].options.env.MISE_ENVRC_PLUGIN, "1", "guard set")
eq(captured[#captured].options.env.DIRENV_DIFF, "", "direnv state blanked")
eq(captured[#captured].options.cwd, "/work/proj", "cwd set")
eq(captured[#captured].options.timeout, 30, "timeout set")
if not captured[#captured].command:find("2> '/tmp/gen/stderr'", 1, true) then
    error("stderr redirect missing")
end

print("test_direnv: ok")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `lua tests/unit/test_direnv.lua`
Expected: FAIL (`module 'direnv' not found`).

- [ ] **Step 3: Implement `lib/direnv.lua`**

```lua
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `lua tests/unit/test_direnv.lua`
Expected: `test_direnv: ok`

- [ ] **Step 5: Commit**

```bash
git add lib/direnv.lua tests/unit/test_direnv.lua
git commit -m "feat: generate per-project direnv whitelist config and read export json"
```

---

### Task 5: `lib/loader.lua` — orchestration, warnings, hand-off cache

**Files:**
- Create: `lib/loader.lua`, `tests/unit/test_loader.lua`

**Interfaces:**
- Consumes: `util.*`, `mise.is_trusted`, `direnv.build_config`, `direnv.export`.
- Produces (`local loader = require("loader")`):
  - `loader.load(ctx, quiet) -> result`
  - `loader.load_cached(ctx) -> result`
  - `loader.emit(result) -> nil`
  - `loader.result_key(cwd, envrc, opts, path_env) -> string`
  - `result = { env = {{key,value}...}, paths = string[], warnings = string[], watch_files = string[], envrc = string|nil, cwd = string|nil, key = string|nil }`

- [ ] **Step 1: Write the failing unit test**

`tests/unit/test_loader.lua`:

```lua
package.path = "./lib/?.lua;./tests/unit/?.lua;" .. package.path
local stubs = require("stubs")
local util = require("util")
local loader = require("loader")

local function eq(a, b, label)
    if a ~= b then error((label or "eq") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

local opts = { direnv_bin = "direnv", timeout = 30, state_dir = nil, dotenv = false }
local k1 = loader.result_key("/work/proj", "/work/proj/.envrc", opts, "/usr/bin")
local k2 = loader.result_key("/work/proj", "/work/proj/.envrc", opts, "/usr/bin")
eq(k1, k2, "cache key stable")
local k3 = loader.result_key("/work/proj", "/work/proj/.envrc", opts, "/usr/bin:/extra")
if k1 == k3 then error("cache key ignores PATH") end

local emitted = {}
stubs.log.warn = function(msg) emitted[#emitted + 1] = msg end
local result = util.map_diff({
    FOO = "bar", GONE = stubs.NULL, PATH = "/old:/base:/tail",
}, "/old:/base", function(v) return v == stubs.NULL end,
    { env = {}, paths = {}, warnings = {} })
eq(#result.env, 1, "env count")
eq(#result.warnings, 1, "one combined warning")
if not result.warnings[1]:find("unset GONE", 1, true) then error("missing unset detail") end
if not result.warnings[1]:find("PATH change", 1, true) then error("missing PATH detail") end
loader.emit(result)
eq(#emitted, 1, "emit count")

-- guard: MISE_ENVRC_PLUGIN=1 must short-circuit without running direnv
local real_getenv = os.getenv
os.getenv = function(k) if k == "MISE_ENVRC_PLUGIN" then return "1" end return nil end
stubs.cmd.exec = function() error("must not run a command") end
local guarded = loader.load({ options = {} }, false)
eq(#guarded.env, 0, "guard env empty")
eq(#guarded.paths, 0, "guard paths empty")
os.getenv = real_getenv

print("test_loader: ok")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `lua tests/unit/test_loader.lua`
Expected: FAIL (`module 'loader' not found`).

- [ ] **Step 3: Implement `lib/loader.lua`**

```lua
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
    }, "\0")
    return util.hash(table.concat({ cwd, envrc, mtime, o, path_env or "" }, "\0"))
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
```

- [ ] **Step 4: Run the unit tests**

Run: `for t in tests/unit/test_*.lua; do lua "$t" || exit 1; done`
Expected: `test_direnv: ok`, `test_loader: ok`, `test_trust: ok`, `test_util: ok`

- [ ] **Step 5: Commit**

```bash
git add lib/loader.lua tests/unit/test_loader.lua
git commit -m "feat: orchestrate discovery, trust, direnv load and hook hand-off cache"
```

---

### Task 6: Wire the hooks and add the core end-to-end suite

**Files:**
- Modify: `hooks/mise_env.lua`, `hooks/mise_path.lua`
- Delete: `tests/smoke.sh` (replaced by `tests/e2e.sh`)
- Create: `tests/e2e.sh`

**Interfaces:**
- Consumes: `loader.load(ctx, false)`, `loader.load_cached(ctx)`.
- Produces: mise hook return values: `MiseEnv` -> `{env, cacheable, watch_files, redact}`; `MisePath` -> `string[]`.

- [ ] **Step 1: Replace the hook stubs**

`hooks/mise_env.lua`:

```lua
local loader = require("loader")

function PLUGIN:MiseEnv(ctx)
    local result = loader.load(ctx, false)
    return {
        env = result.env or {},
        cacheable = false,
        watch_files = result.watch_files or {},
        redact = false,
    }
end
```

`hooks/mise_path.lua`:

```lua
local loader = require("loader")

function PLUGIN:MisePath(ctx)
    local result = loader.load_cached(ctx)
    return result.paths or {}
end
```

- [ ] **Step 2: Write the failing e2e test (cases 1–6)**

```bash
#!/usr/bin/env bash
# tests/e2e.sh — end-to-end tests against real mise + direnv.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
S=$(mktemp -d "${TMPDIR:-/tmp}/mise-envrc-e2e.XXXXXX")
trap 'rm -rf "$S"' EXIT

mkdir -p "$S/config" "$S/data" "$S/state" "$S/cache" "$S/direnv/lib" \
         "$S/xdg-data" "$S/xdg-state" "$S/xdg-cache"
export MISE_CONFIG_DIR="$S/config" MISE_DATA_DIR="$S/data" \
       MISE_STATE_DIR="$S/state" MISE_CACHE_DIR="$S/cache" \
       DIRENV_CONFIG="$S/direnv" XDG_DATA_HOME="$S/xdg-data" \
       XDG_STATE_HOME="$S/xdg-state" XDG_CACHE_HOME="$S/xdg-cache"
printf '[env]\n_.envrc = { }\n' > "$S/config/config.toml"
mise plugins link envrc "$ROOT" >/dev/null 2>&1

fail=0
check() {
  local label=$1 expected=$2 actual=$3
  if [ "$actual" != "$expected" ]; then
    echo "FAIL $label: expected '$expected', got '$actual'" >&2; fail=1
  else echo "ok $label"; fi
}
envval() { (cd "$1" && mise env --json 2>"$S/stderr" | jq -r --arg k "$2" '.[$k] // ""'); }
hasvar() { (cd "$1" && mise env --json 2>/dev/null | jq -e --arg k "$2" 'has($k)') >/dev/null; }

# fixture A: trusted, .envrc with dotenv and PATH_add
A="$S/projA"; mkdir -p "$A/bin" "$A/sub"
printf 'export PROJECT_NAME=alpha\ndotenv_if_exists .env.local\nPATH_add bin\n' > "$A/.envrc"
printf 'FROM_DOTENV=yes\n' > "$A/.env.local"
mise trust "$A" >/dev/null 2>&1
check "trusted project var" "alpha" "$(envval "$A" PROJECT_NAME)"
check "dotenv loaded" "yes" "$(envval "$A" FROM_DOTENV)"
check "PATH_add prepended" "$A/bin" "$(envval "$A" PATH | cut -d: -f1)"

# case 6: from a subdirectory
check "parent .envrc from subdir" "alpha" "$(envval "$A/sub" PROJECT_NAME)"

# case 2: each mise config filename causes a skip
for cfg in "mise.toml" ".mise.toml" "mise.local.toml" ".config/mise/config.toml"; do
  B="$S/skip-${cfg//\//_}"; mkdir -p "$B/$(dirname "$cfg")"
  printf 'export SKIPPED_VAR=nope\n' > "$B/.envrc"
  printf '[env]\n' > "$B/$cfg"
  mise trust "$B" >/dev/null 2>&1
  check "skip with $cfg" "" "$(envval "$B" SKIPPED_VAR)"
done

# case 3: untrusted
C="$S/projC"; mkdir -p "$C"
printf 'export UNTRUSTED_VAR=nope\n' > "$C/.envrc"
check "untrusted skipped" "" "$(envval "$C" UNTRUSTED_VAR)"

# case 4: trust then untrust
mise trust "$C" >/dev/null 2>&1
check "trust enables" "nope" "$(envval "$C" UNTRUSTED_VAR)"
mise trust --untrust "$C" >/dev/null 2>&1
check "untrust disables" "" "$(envval "$C" UNTRUSTED_VAR)"

# case 5: ignore wins
mise trust "$C" >/dev/null 2>&1
mise trust --ignore "$C" >/dev/null 2>&1
check "ignore blocks" "" "$(envval "$C" UNTRUSTED_VAR)"

[ "$fail" -eq 0 ] || exit 1
echo "e2e core: ok"
```

- [ ] **Step 3: Run the e2e test**

Run: `bash tests/e2e.sh`
Expected: FAIL on the first assertion if the hooks are still stubs; after Step 1 all core cases should pass. Fix any failing case before proceeding (use `MISE_DEBUG=1 mise env --json` to inspect hook errors). Remove `tests/smoke.sh`.

- [ ] **Step 4: Verify no internal variables leak**

Run: `bash tests/e2e.sh`
Expected: all core cases print `ok`. Internal-variable leakage is asserted as case 10 in Task 7.

- [ ] **Step 5: Commit**

```bash
git rm tests/smoke.sh
git add hooks lib tests/e2e.sh
git commit -m "feat: wire MiseEnv/MisePath hooks and add core end-to-end tests"
```

---

### Task 7: Edge-case e2e coverage and fixes

**Files:**
- Modify: `tests/e2e.sh`, and any of `lib/*.lua` / `hooks/*.lua` that fail a case

**Interfaces:**
- Consumes: all interfaces from Tasks 2–6.
- Produces: no new interfaces; fixes must preserve every signature above.

- [ ] **Step 1: Add failing edge-case tests**

Append to `tests/e2e.sh` before the final `[ "$fail" -eq 0 ]`:

```bash
# case 7: unset and PATH append are warned about, other vars still apply
D="$S/projD"; mkdir -p "$D"
printf 'export KEPT_VAR=yes\nunset GONE_VAR\nexport PATH="$PATH:/appended"\n' > "$D/.envrc"
mise trust "$D" >/dev/null 2>&1
check "kept var with unsupported ops" "yes" "$(envval "$D" KEPT_VAR)"
(cd "$D" && mise env >/dev/null 2>"$S/warnD")
if ! grep -q "operations mise cannot express" "$S/warnD"; then
  echo "FAIL unsupported-op warning" >&2; fail=1
else echo "ok unsupported-op warning"; fi

# case 8: `use mise` in direnvrc must not recurse or emit the deprecation warning
printf 'use mise\n' > "$S/direnv/direnvrc"
E="$S/projE"; mkdir -p "$E"
printf 'export USE_MISE_OK=yes\n' > "$E/.envrc"
mise trust "$E" >/dev/null 2>&1
(cd "$E" && timeout 30 mise env --json >"$S/envE" 2>"$S/warnE")
check "use mise does not recurse" "yes" "$(jq -r '.USE_MISE_OK // ""' "$S/envE")"
if grep -q "deprecated \[cli.direnv\]" "$S/warnE"; then
  echo "FAIL deprecated warning leaked" >&2; fail=1
else echo "ok no deprecated warning"; fi
rm -f "$S/direnv/direnvrc"

# case 9a: MISE_SAFE=1 disables loading
F="$S/projF"; mkdir -p "$F"
printf 'export SAFE_VAR=no\n' > "$F/.envrc"
mise trust "$F" >/dev/null 2>&1
check "safe mode" "" "$(cd "$F" && MISE_SAFE=1 mise env --json 2>/dev/null | jq -r '.SAFE_VAR // ""')"

# case 9b: missing direnv warns without breaking mise env
check "baseline with explicit config dir" "yes" \
  "$(cd "$A" && MISE_CONFIG_DIR="$S/config" mise env --json 2>/dev/null | jq -r '.PROJECT_NAME // ""')"
G="$S/nodirenv"; mkdir -p "$G/config" "$G"
printf '[env]\n_.envrc = { direnv_bin = "%s/does-not-exist" }\n' "$G" > "$G/config/config.toml"
printf 'export NO_DIRENV_VAR=nope\n' > "$G/.envrc"
mise trust "$G" >/dev/null 2>&1
(cd "$G" && MISE_CONFIG_DIR="$G/config" mise env --json >"$S/envG" 2>"$S/warnG")
check "missing direnv skipped" "" "$(jq -r '.NO_DIRENV_VAR // ""' "$S/envG")"
if ! grep -q "direnv not found" "$S/warnG"; then
  echo "FAIL missing direnv warning" >&2; fail=1
else echo "ok missing direnv warning"; fi

# case 10: no internal variables leak
leaks=$(cd "$A" && mise env --json | jq -r 'keys[]' |
  grep -cE '^(DIRENV_|__MISE_|MISE_ENVRC_PLUGIN)' || true)
check "no internal vars" "0" "$leaks"

# case 11: direnv's allow DB is unchanged
allows_before=$(find "$S/xdg-data/direnv/allow" -type f 2>/dev/null | wc -l)
(cd "$A" && mise env >/dev/null 2>&1)
allows_after=$(find "$S/xdg-data/direnv/allow" -type f 2>/dev/null | wc -l)
check "direnv allow DB untouched" "$allows_before" "$allows_after"
```


- [ ] **Step 2: Run the full e2e suite**

Run: `bash tests/e2e.sh`
Expected: FAIL on whichever case exposes a bug. Fix the implementation (not the assertions) and re-run until all cases print `ok`.

- [ ] **Step 3: Run all unit tests again**

Run: `for t in tests/unit/test_*.lua; do lua "$t" || exit 1; done`
Expected: all four `...: ok` lines.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "test: cover unsupported ops, recursion, safe mode and internal-var leaks"
```

---

### Task 8: Documentation, license, and final verification

**Files:**
- Create: `README.md`, `LICENSE`

**Interfaces:**
- Consumes: the finished plugin.
- Produces: user-facing docs and a complete, passing repository.

- [ ] **Step 1: Write `README.md`**

```markdown
# mise-envrc-plugin

A [mise](https://mise.jdx.dev) **environment plugin** that loads `.envrc` files
for projects that have no mise configuration. Intended for repositories owned by
other people, where you cannot replace a committed `.envrc` with `mise.toml`.

mise is deprecating its direnv integration (`use mise`, removal in mise
2027.10.4) and recommends migrating to `mise.toml`. This plugin lets you drop
direnv's shell hook while still loading those `.envrc` files.

## Requirements

- mise with environment-plugin hooks (`MiseEnv` / `MisePath`); verified on
  mise 2026.10.17.
- direnv >= 2.34.0 (`direnv export json`); verified on 2.38.2.
- bash, Linux or macOS. Windows is not supported.

## Install

```sh
mise plugins install envrc <repository-url>
# or, for a local checkout:
mise plugins link envrc /path/to/mise-envrc-plugin
```

Enable it once in your **global** config:

```toml
# ~/.config/mise/config.toml
[env]
_.envrc = { }
```

Then remove direnv's shell hook (`eval "$(direnv hook zsh)"`) from your shell
startup, and remove the deprecated `use mise` line from
`~/.config/direnv/direnvrc` and `~/.config/direnv/lib/use_mise.sh`.

## Trust

Nothing is executed until mise trusts the project. Approve one project with:

```sh
mise trust /path/to/project
```

or trust a whole tree in `~/.config/mise/config.toml`:

```toml
[settings]
trusted_config_paths = ["~/src/work"]
```

`mise trust --untrust <dir>` or `mise trust --ignore <dir>` revokes access.
`ignored_config_paths` always wins. `MISE_SAFE=1` disables the plugin. In
paranoid mode, approval is tied to the `.envrc` contents: editing it requires
re-approval. `direnv allow` is not used and is not needed.

`mise trust --show` does not list `.envrc`-only projects (mise only lists
config directories); that is expected.

## Options

```toml
[env]
_.envrc = { direnv_bin = "direnv", timeout = 30, state_dir = "/path", dotenv = false }
```

| Option | Default | Meaning |
| --- | --- | --- |
| `direnv_bin` | `direnv` | direnv executable name or path |
| `timeout` | `30` | seconds allowed per direnv invocation |
| `state_dir` | unset | override mise's state directory for trust records |
| `dotenv` | `false` | also discover `.env` files |

`redact = true` and `tools = true` are mise directive options and work as usual.

## Behaviour

- The nearest `.envrc` is found by walking up from the current directory, as
  direnv does. `.env` files are found too when `dotenv = true`.
- If **any** mise config exists from the current directory up to the `.envrc`
  directory (`mise.toml`, `.mise.toml`, `mise.local.toml`, `mise/conf.d/*.toml`,
  `.config/mise.toml`, `.tool-versions`, …), the `.envrc` is skipped — mise
  config wins.
- The plugin builds a private direnv config that whitelists exactly that one
  approved `.envrc`, preserving your `direnvrc` helpers and `lib/*.sh` (including
  nix-direnv) while neutralising `use mise`. direnv's own allow database is not
  touched.
- Variables are returned from `MiseEnv`; directories prepended by `PATH_add`
  are returned from `MisePath`. mise stays in control of tool paths.

## Limitations

- `unset VAR`, PATH appends/reorders/removals and shell functions/aliases cannot
  be expressed through mise's plugin API. They are warned about once and ignored;
  all other variables still apply.
- direnv's `watch_file` reloads are not honoured; mise recomputes the environment
  on directory/config changes and on `mise env`.
- The generated direnv config does not inherit `[whitelist]`, `load_dotenv`,
  `strict_env` or `bash_path` from your `direnv.toml` (only scalar `[global]`
  settings). Use the `dotenv` and `direnv_bin` options for the common cases.
- mise's trust-record directory layout is internal; the `state_dir` option lets
  you override it if your setup differs.
- Running direnv and mise shell hooks together remains unsupported by mise. Do
  not enable both.

## Development

```sh
for t in tests/unit/test_*.lua; do lua "$t"; done
bash tests/e2e.sh
```
```

- [ ] **Step 2: Write `LICENSE`**

Use the standard MIT license text with `Copyright (c) 2026 mise-envrc-plugin contributors`.

- [ ] **Step 3: Run the complete verification suite**

Run:
```bash
for t in tests/unit/test_*.lua; do lua "$t" || exit 1; done
bash tests/e2e.sh
git status --short
```
Expected: four `...: ok` unit lines, `e2e core: ok`, and a clean working tree after the next commit.

- [ ] **Step 4: Commit**

```bash
git add README.md LICENSE
git commit -m "docs: document install, trust workflow, options and limitations"
```

---

## Self-review

- **Spec coverage:** every spec section maps to a task — setup/metadata (1), discovery/skip/diff helpers (2), trust store/settings/paranoid hashes (3), generated direnv config/export/whitelist/lib farm (4), guards/options/errors/hand-off cache/warnings (5), hooks (6), all 11 e2e cases (6, 7), README/license (8).
- **Placeholder scan:** no TBD/TODO, no "add appropriate handling", no "similar to Task N"; every code-changing step contains full code; every test step contains full test code and exact commands.
- **Type consistency:** `util.*`, `mise.*`, `direnv.*`, `loader.*` names are identical in Interfaces, implementation, and call sites. `result` fields (`env`, `paths`, `warnings`, `watch_files`, `envrc`, `cwd`, `key`) are identical in `loader.load`, `loader.load_cached`, and the hooks.
