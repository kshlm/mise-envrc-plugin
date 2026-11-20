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
