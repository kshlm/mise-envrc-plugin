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
check "baseline with explicit config dir" "alpha" \
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
allows_before=$(find "$S/xdg-data/direnv/allow" -type f 2>/dev/null | wc -l || true)
(cd "$A" && mise env >/dev/null 2>&1)
allows_after=$(find "$S/xdg-data/direnv/allow" -type f 2>/dev/null | wc -l || true)
check "direnv allow DB untouched" "$allows_before" "$allows_after"

[ "$fail" -eq 0 ] || exit 1
echo "e2e core: ok"
