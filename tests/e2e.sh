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

[ "$fail" -eq 0 ] || exit 1
echo "e2e core: ok"
