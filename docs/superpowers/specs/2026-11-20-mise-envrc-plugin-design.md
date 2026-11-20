# mise-envrc-plugin — Design

Status: approved design, pending spec review
Date: 2026-11-20

Notation: in snippets, `<...>` denotes a value substituted at runtime. Every such value is
either computed by the algorithm below or supplied by the user as documented; no
substitution is left undefined.

## Problem

mise deprecates its direnv integration (`use mise` / `mise direnv activate`, removal in
mise 2027.10.4) and recommends moving every `.envrc` into `mise.toml`. For projects owned
by other people, that migration is not possible: the `.envrc` is committed upstream and
cannot be replaced. Running direnv's shell hook together with `mise activate` is explicitly
unsupported by mise.

Goal: a mise **environment plugin** that, when enabled once in the user's global mise
config, loads the nearest `.envrc` for any directory that has no mise configuration, using
mise's own trust store as the single approval mechanism. No direnv shell hook, no changes
to any third-party repository, no `direnv allow` step.

## Non-goals

- Replacing mise.toml. Projects that have any mise config are skipped outright.
- Providing direnv's shell-hook semantics: automatic reload on `watch_file`,
  prompt-based approval, and shell function exports.
- Supporting Windows. `.envrc` execution requires POSIX bash.
- Supporting `.envrc` constructs mise cannot express (see "Env diff mapping").
- Installing tools. This is an environment plugin; it installs nothing.

## Prerequisites

- mise with `MiseEnv` / `MisePath` hook support (verified against local mise 2026.10.17).
- direnv >= 2.34.0, when `direnv export` became a documented (non-private)
  command; its `json` target is verified against local direnv 2.38.2.
- bash, available to direnv's stdlib.
- `mise activate` in the shell; the `direnv hook` line must be removed from shell startup.

Verified facts this design relies on:

1. `direnv help export` lists `json` as a supported SHELL target.
   `internal/cmd/cmd_export.go` renders `currentEnv.Diff(newEnv).ToShell(shell)`.
2. `direnv export json` prints a JSON object of the environment **diff**: changed/added
   keys as strings, removed keys as `null`, the resulting full `PATH`, plus direnv's
   internal `DIRENV_DIFF`, `DIRENV_DIR`, `DIRENV_FILE`, `DIRENV_WATCHES`.
3. An unapproved `.envrc` still yields exit status 0 with
   `direnv: error ... is blocked. Run direnv allow` on stderr and omits the project's
   variables. Trust therefore cannot be inferred from the exit code alone.
4. With no `.envrc` found, `direnv export json` prints nothing.
5. `direnv status --json` reports `foundRC.allowed` as `0 = Allowed`, `1 = NotAllowed`,
   `2 = Denied` (`internal/cmd/rc.go`). `[whitelist] exact = ["<abs .envrc>"]` in
   `direnv.toml` makes an otherwise-unapproved file `Allowed` without any allow record.
   Verified locally: with a generated config, the `.envrc` loads and direnv's allow DB is
   untouched.
6. In normal mode, `mise trust <path>` records trust for the **directory** as a symlink
   in `$MISE_STATE_DIR/trusted-configs`; in paranoid mode it records the file path plus a
   content hash sidecar. `mise trust --ignore` adds the same shape of record in
   `$MISE_STATE_DIR/ignored-configs`; `mise trust --untrust` removes them.
   `mise trust --show` is not usable here: in a directory with no mise config it reports
   "No trusted config files found" even after trust was granted.
7. `mise --no-env settings --all --json` returns, among other settings,
   `trusted_config_paths`, `ignored_config_paths` and `paranoid`.
8. mise calls `MiseEnv` and `MisePath` in that order, in separate Lua VMs
   (`src/config/env_directive/module.rs`, `crates/vfox/src/vfox/hooks.rs`), so no in-memory
   state can be shared between the two hooks.
9. `MiseEnv` can only return `{key, value}` string pairs; `MisePath` returns directories
   to prepend. There is no "unset" operation in the plugin API.

## User-facing setup

```toml
# ~/.config/mise/config.toml
[env]
_.envrc = { }
```

Install the plugin with `mise plugins install envrc <repository-url>` (the URL of the
published repo), or with `mise plugins link envrc <checkout-path>` for a local checkout.
A `[plugins]` entry in the global config is optional; when used, its value is that same
repository URL. The directive must be in the global config so it applies to repositories
the user does not own.

For development: `mise plugins link envrc ./mise-envrc-plugin`.

Optional directive keys handled by mise itself (not passed to the plugin):
`redact = true` masks all loaded values in mise logs/task output; `tools = true` resolves
the directive after configured tools are on `PATH`.

Approving a project is a single command, `mise trust <project-dir>` (or listing a parent
under `[settings] trusted_config_paths`). Revoking is `mise trust --untrust <project-dir>`.

The README instructs the user to remove `use mise` from
`~/.config/direnv/direnvrc` and `~/.config/direnv/lib/use_mise.sh` as part of the
migration. The plugin still guards against it (see Detailed algorithm steps 1 and 6,
and Security considerations).

## Architecture

```
mise hook-env / mise env
  └── [env] _.envrc directive (global config)
        ├── hooks/mise_env.lua ─┐
        └── hooks/mise_path.lua ─┴── lib/loader.lua
                                      ├── lib/util.lua    (pure helpers)
                                      ├── lib/mise.lua    (trust store + settings)
                                      └── lib/direnv.lua  (generated config + export json)
                                                └── direnv CLI ── bash + direnv stdlib
                                                                    └── project .envrc
```

`lib/loader.lua` is the only component that knows the whole algorithm. `lib/util.lua`
holds pure functions so they can be unit tested in plain Lua 5.1.

## File layout

```
metadata.lua
hooks/mise_env.lua
hooks/mise_path.lua
lib/util.lua
lib/mise.lua
lib/direnv.lua
lib/loader.lua
README.md
LICENSE
tests/unit/test_util.lua
tests/unit/test_loader.lua
tests/e2e.sh
docs/superpowers/specs/2026-11-20-mise-envrc-plugin-design.md
```

`metadata.lua` declares exactly:

```lua
PLUGIN = {
    name = "envrc",
    version = "0.1.0",
    description = "Load .envrc files for projects that have no mise config",
    license = "MIT",
}
```

`homepage` is omitted until the repository is published. The installed plugin name and
the directive suffix are both `envrc` (mise resolves plugin directory names in kebab case).

## Detailed algorithm

Both hooks call `lib/loader.lua` with `ctx` and a `quiet` flag. The result is a table
`{ env = { {key, value}, ... }, paths = { "<dir>", ... }, warnings = { "<msg>", ... },
envrc = "<abs path>" | nil }`.

### 1. Guards (first action in both hooks)

- If `os.getenv("MISE_ENVRC_PLUGIN") == "1"`, return an empty result. This breaks the
  `use mise` -> `mise direnv exec` -> plugin -> direnv cycle.
- If `MISE_SAFE` is `1` or `true`, return an empty result. The directive lives in the
  global config, which safe mode still applies, so the plugin must enforce this itself.
- If `direnv_bin` is not executable (`cmd.exec("<bin> version", { timeout = 5 })` inside
  `pcall`), warn once and return an empty result. A missing direnv must not break every
  command in the directory.

### 2. Resolve the working directory

`cmd.exec("pwd -P")` (output trimmed with `strings.trim_space`). The physical path is used
because direnv's `os.Getwd()` also resolves symlinks. `ctx.config_root` is deliberately
**not** used: for a global directive it is the user's config directory, not the project.

### 3. Discover the rc file

Walk from cwd up to the filesystem root. In each directory, check `.envrc` first, then
`.env` when the `dotenv` option is true (matching direnv's `findUp` order). The first
existing regular file wins. Absolute path is kept as `envrc`. No rc file -> silent no-op.
The walk is bounded by the filesystem root; the plugin does not honor
`MISE_CEILING_PATHS`.

### 4. Skip projects that already have mise config

Let `project_dir = dirname(envrc)`. For every directory from cwd up to and including
`project_dir` (inclusive), check for any of:

- `mise*.toml`, `.mise*.toml` (covers `mise.toml`, `.mise.toml`, `mise.local.toml`,
  `.mise.local.toml`, and env-specific `mise.<env>.toml` variants);
- `mise/*.toml`, `mise/conf.d/*.toml`, `mise/conf.d/*/mise*.toml`;
- `.mise/*.toml`, `.mise/conf.d/*.toml`;
- `.config/mise*.toml`, `.config/mise/*.toml`, `.config/mise/conf.d/*.toml`;
- `.tool-versions`.

Any match -> return an empty result with a `log.debug` note. The global config in
`~/.config/mise/config.toml` is outside this range except when `project_dir` is `$HOME`
or an ancestor of it, in which case skipping is intentional.

### 5. Trust check (mise's allowlist)

Settings are read once with
`mise --no-env settings --all --json` (run with `MISE_NO_ENV=1` and
`MISE_ENVRC_PLUGIN=1` so it cannot re-enter the plugin), parsed with `json.decode`, and
reduced to `trusted_config_paths`, `ignored_config_paths`, `paranoid`.

The state directory is `state_dir` option, else `MISE_STATE_DIR`, else
`$XDG_STATE_HOME/mise`, else `$HOME/.local/state/mise`. Trusted and ignored records are
the symlink targets in `<state>/trusted-configs` and `<state>/ignored-configs`. They are
enumerated with one POSIX shell command of the form
`for f in '<dir>'/*; do [ -L "$f" ] && readlink "$f"; done` (paths shell-quoted),
yielding newline-separated absolute targets.

Path matching is boundary aware: target `T` matches directory `D` when `D == T` or
`D` starts with `T .. "/"`. `~` in configured paths expands to `HOME`.

Precedence is deliberately **deny-wins** (stricter than mise's normal mode):

1. If `project_dir` matches any `ignored_config_paths` entry or any `ignored-configs`
   target -> never load.
2. If `paranoid` is true -> require an exact trust record whose target equals `envrc`
   (the file path), **and** verify that the sibling `<record-name>.hash` file contains the
   SHA-256 hex digest of the current `.envrc` contents. In paranoid mode mise stores one
   symlink to the file plus a 64-byte `<record-name>.hash` sidecar; the digest is of the
   file contents alone (verified locally). The plugin computes the digest with
   `sha256sum` on Linux or `shasum -a 256` on macOS through `cmd.exec`. A missing sidecar
   or a digest mismatch means "not trusted". Directory/prefix trust is not sufficient in
   this mode, matching mise's per-file, content-bound trust model.
3. Otherwise, load if `project_dir` matches a `trusted_config_paths` prefix, a
   `trusted-configs` target, or an exact `envrc` trust record.

If not trusted: one `log.warn` of the form
`mise-envrc: <envrc> is not trusted by mise; run 'mise trust <project_dir>' to load it`
and no direnv execution.

### 6. Generated direnv config (approach A)

Root: `RUNTIME.cacheDirPath/direnv/<hex>` where `<hex>` is an FNV-1a hash of the absolute
`envrc` path. If `RUNTIME.cacheDirPath` is nil (mise could not create it), warn once and
return an empty result; the plugin does not fall back to a world-writable directory.

The directory contains a `version` file with content `1`. If the version is missing or
different, the directory is removed with a shell-quoted `rm -rf '<gen>'` and rebuilt with
`mkdir -p '<gen>/lib'`. Contents:

- `direnv.toml`:
  ```toml
  [whitelist]
  exact = ["<abs .envrc>"]

  [global]
  hide_env_diff = true
  log_format = ""
  ```
  Additionally, best-effort copies of scalar keys from the user's real
  `$DIRENV_CONFIG/direnv.toml` (or `config.toml`) `[global]` table (and its legacy
  top-level form) are appended **inside the `[global]` table**, with `log_format` and
  `hide_env_diff` excluded because the generated values take precedence. Only
  single-line `key = value` pairs are copied; tables, arrays and multi-line values are
  skipped. Reading/parsing failures are caught with `pcall` and simply leave the defaults
  in place. User `[whitelist]` entries and `load_dotenv` / `strict_env` are **not**
  inherited; the plugin's `dotenv` option covers the discovery case, and this is
  documented in the README.
- `lib/`: a symlink farm of every `*.sh` in the user's real
  `$DIRENV_CONFIG/lib/`. Files whose content contains `mise direnv` are skipped: those
  are the deprecated `use mise` shims (e.g. `use_mise.sh`, `hm-mise.sh`). Everything
  else, notably nix-direnv's `hm-nix-direnv.sh`, is preserved so `use nix` / `use flake`
  keep working. Verified locally that omitting the mise shim removes the deprecation
  warning from the direnv subprocess.
- `direnvrc`: first line `use_mise() { :; }`, then `source '<real direnvrc>'` for
  `$DIRENV_CONFIG/direnvrc` and/or `$HOME/.direnvrc` when present. Custom helpers in the
  user's direnvrc therefore still work, while a stray `use mise` call becomes a no-op.

Files are written with Lua `io.open(path, "w")`; symlinks with `file.symlink`. If `io` is
unavailable in mise's Lua sandbox, the fallback is `cmd.exec` with a shell-quoted
`printf '%s' ... > '<path>'`. Shell-quoting of every interpolated path is mandatory.

### 7. Run direnv

```
'<direnv_bin>' export json 2> '<gen>/stderr'
```

Both substitutions are single-quote escaped; `<gen>` is the generated config directory
and `<direnv_bin>` is the configured binary path.

`cmd.exec` options:

- `cwd = cwd`;
- `env` merges: `DIRENV_CONFIG = <gen>`, `DIRENV_LOG_FORMAT = ""`,
  `MISE_ENVRC_PLUGIN = "1"`, `DIRENV_DIFF = ""`, `DIRENV_DIR = ""`,
  `DIRENV_FILE = ""`, `DIRENV_WATCHES = ""`, `DIRENV_IN_ENVRC = ""`,
  `DIRENV_DISABLE = ""` (blanking the first four neutralizes any residual direnv hook
  state inherited from a previously activated shell);
- `timeout = opts.timeout`.

Calls are wrapped in `pcall`; a non-zero exit or timeout produces one warning and an
empty result. stdout is decoded with `json.decode` inside `pcall` (empty stdout is a
no-op, not an error). `<gen>/stderr` is read with `file.read` inside `pcall`; if it
contains `direnv: error`, `is blocked` or `error ` the first relevant line is surfaced as
one warning. Ordinary status lines are ignored.

### 8. Env diff mapping

Let `NULL = json.decode("null")` (mise's `json` module decodes JSON null to a truthy
sentinel, not `nil`). Iterate the decoded object in sorted key order for deterministic
output.

- Drop keys matching `^DIRENV_`, `^__MISE_`, and the exact key `MISE_ENVRC_PLUGIN`.
  These are direnv/mise internals and must never be exported to the user's shell.
- `value == NULL` -> collect the key as an unsupported `unset` operation.
- `PATH` -> compare against `os.getenv("PATH")` from the hook environment:
  - equal -> no path additions;
  - `new == "<prepends>:" .. old` -> split `<prepends>` on `:` and return every non-empty
    entry, in order, as MisePath additions;
  - otherwise -> collect an unsupported PATH change (append, reorder or removal).
  The plugin never returns a `PATH` key from `MiseEnv`, so mise keeps control of tool
  paths and PATH ordering.
- Any other value: require `type(value) == "string"`; otherwise warn and ignore. Emit
  `{ key = k, value = v }`.

Unsupported operations produce one combined warning per env build, e.g.
`mise-envrc: <envrc> uses operations mise cannot express (unset GOOSE, PATH reorder);
they were ignored`. They are **warned about and ignored**; all other variables still
apply. Warnings are emitted from `MiseEnv` only; `MisePath` calls the loader with
`quiet = true` to avoid duplicates.

### 9. Hook results

- `MiseEnv(ctx)` -> `{ env = <list>, cacheable = false,
  watch_files = { envrc }, redact = false }`. `cacheable = false` guarantees the `.envrc`
  is re-evaluated whenever mise rebuilds the environment; `watch_files` still names the
  file for cache invalidation when `MISE_ENV_CACHE=1`.
- `MisePath(ctx)` -> `<list of prepended directories>`.
- Empty-result guards return `{ env = {}, cacheable = false, watch_files = {} }` and
  `{}` respectively.

### 10. One direnv invocation per env build

mise calls `MiseEnv` before `MisePath` in separate Lua VMs. The loader therefore writes
its result as JSON to `<cache>/result-<key>.json`, atomically via
`<cache>/result-<key>.json.tmp` + `file.move`. `<key>` is an FNV-1a hash of the
concatenation of cwd, `envrc`, `envrc` mtime (`file.stat(envrc).modified`), the sorted
JSON encoding of the directive options, and the hook `PATH`. `MiseEnv` writes the file;
`MisePath` reads it and validates the key. On any mismatch, read failure or parse failure,
`MisePath` recomputes by running direnv a second time rather than returning stale data.

## Error handling

| Condition | Behaviour |
| --- | --- |
| No `.envrc` found | Silent no-op |
| Project has any mise config | Silent no-op (`log.debug`) |
| Not trusted / ignored / `MISE_SAFE=1` | One warning, no execution, empty result |
| direnv binary missing | One warning with install hint, no execution |
| `.envrc` blocked or script error | One warning from captured stderr, empty or partial result (direnv exits 0 in these cases) |
| JSON decode failure, timeout, non-zero exit | One warning, empty result |
| `RUNTIME.cacheDirPath` unavailable | One warning, empty result |
| `io.open` unavailable | Shell `printf` fallback; if that also fails, one warning, empty result |
| Unsupported `unset` / PATH change | One warning, remaining variables still applied |

No error path raises a Lua `error()` that would break every mise command in the
directory. Error messages never include environment variable values.

## Configuration options

Directive table (`_.envrc = { ... }`):

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `direnv_bin` | string | `"direnv"` | Path/name of the direnv executable |
| `timeout` | number | `30` | Seconds allowed for each direnv invocation |
| `state_dir` | string | unset | Override mise's state directory for trust records |
| `dotenv` | boolean | `false` | Also discover `.env` files, like direnv's `load_dotenv` |

`tools` and `redact` are consumed by mise before the hooks run and are not plugin options.
Unknown option keys are ignored with a `log.debug` note. A string directive such as
`_.envrc = "value"` reaches the plugin as a string, not a table; the plugin treats it as
an empty options table and logs a debug note (the README documents only the table form).

## Security considerations

- Mise's trust store is the only approval mechanism. The plugin never calls
  `direnv allow`, never auto-trusts a new `.envrc`, and never writes to direnv's allow DB.
- Deny-wins precedence; `ignored_config_paths` / `ignored-configs` always override trust.
- Paranoid mode requires a file-level trust record whose `.hash` sidecar matches the
  current `.envrc` contents, so editing an approved file revokes its approval.
- `MISE_SAFE=1` disables loading.
- `MISE_ENVRC_PLUGIN=1` guard plus the `use_mise` no-op prevents recursion through the
  deprecated direnv integration.
- All child `mise` calls use `MISE_NO_ENV=1` and the guard variable.
- Every interpolated path in a shell command is single-quote escaped.
- Timeouts bound untrusted `.envrc` scripts.
- Values are not logged. `redact = true` in the directive makes mise mask all returned
  values in its own output.

## Testing

Unit tests (`lua` 5.1.5 is available locally) load `lib/util.lua` and `lib/loader.lua`
with stubbed `file`, `json`, `cmd`, `log` and `RUNTIME` globals. They cover: directory
walk-up, boundary-aware prefix matching, mise-config skip patterns, PATH prefix
extraction, null/filter handling, warning aggregation, and result-cache key stability.

`tests/e2e.sh` creates an isolated sandbox with its own `MISE_CONFIG_DIR`,
`MISE_DATA_DIR`, `MISE_STATE_DIR`, `MISE_CACHE_DIR` and `DIRENV_CONFIG`, links the plugin
with `mise plugins link envrc .`, and asserts with `mise env --json` / `mise exec --`:

1. a mise-trusted `.envrc` exports variables, `dotenv`, and `PATH_add bin`;
2. `mise.toml`, `.mise.toml`, `mise.local.toml`, `.config/mise/config.toml` each cause
   a skip;
3. an untrusted `.envrc` is not executed and warns;
4. `mise trust <dir>` enables it; `mise trust --untrust <dir>` disables it again;
5. `mise trust --ignore <dir>` and `ignored_config_paths` block even a trusted path;
6. running mise from a subdirectory finds the parent `.envrc` and resolves relative
   paths correctly;
7. `unset VAR` and a PATH append warn and are ignored while other variables still apply;
8. a `use mise` in `direnvrc` causes neither recursion nor a deprecation warning in the
   result;
9. `MISE_SAFE=1`, a missing direnv binary, and a direnv timeout all warn without breaking
   `mise env`;
10. no `DIRENV_*` or `MISE_ENVRC_PLUGIN` variables leak into the final environment;
11. the direnv allow database is unchanged after a successful load.

## Limitations

- mise's trust-record directory layout (`trusted-configs` / `ignored-configs` symlinks)
  is internal, not a documented plugin API. The plugin pins to the observed format, logs
  a warning if the state directory cannot be read, and the `state_dir` option lets users
  override it.
- `mise trust --show` does not list `.envrc`-only projects; approval is
  `mise trust <project-dir>`.
- direnv's `direnv.toml` `[whitelist]`, `load_dotenv`, `strict_env` and `bash_path`
  settings are not inherited into the generated config (aside from best-effort `[global]`
  scalars). `dotenv` and `direnv_bin` options mitigate the common cases.
- `unset`, PATH append/reorder/removal, and direnv `watch_file`-driven reloads are not
  supported. mise recomputes the environment on directory/config changes and on
  `mise env`; it does not watch arbitrary files named by an `.envrc`.
- Shell aliases and shell functions defined by `.envrc` are not transferred; only
  environment variables and prepended PATH entries are.
- Windows is unsupported.
- Two hooks each call the loader; the hand-off cache normally reduces this to one direnv
  invocation, but a cache miss causes a second invocation.

## Implementation risks to verify first

1. `io.open` availability inside mise's embedded Lua 5.1. Fallback: shell-quoted
   `printf` redirect via `cmd.exec`.
2. `file.symlink(src, dst)` direction and behaviour when `dst` already exists. Fallback:
   rebuild the generated directory before creating links.
3. `mise --no-env settings --all --json` run from inside an env hook (guard variables
   must prevent recursion). Fallback: read `MISE_TRUSTED_CONFIG_PATHS` /
   `MISE_IGNORED_CONFIG_PATHS` from the hook environment and skip settings lookup.
4. `RUNTIME.cacheDirPath` is created before hooks run. Verified by mise documentation;
   the nil case is handled as an error path above.

## Acceptance criteria

- With the plugin enabled only in the global config, `cd`-ing into a mise-trusted project
  with an `.envrc` and no mise config yields that `.envrc`'s variables and PATH additions
  in `mise env --json`, with no direnv shell hook and no `direnv allow` command.
- The same project with any mise config file yields none of those variables.
- An untrusted project executes nothing.
- All 11 e2e cases and the unit tests pass.
- README documents installation, the trust workflow, options, limitations, and the mise
  version requirement.
