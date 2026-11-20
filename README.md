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
