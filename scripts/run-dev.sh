#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_BIN="$ROOT_DIR/build/AgyHigher.app/Contents/MacOS/AgyHigher"

if [ ! -x "$APP_BIN" ]; then
  "$ROOT_DIR/scripts/build.sh"
fi

# Default to isolated .dev-sandbox during development. Pass --live to use real ~/.gemini/antigravity-cli.
if [[ "${1:-}" == "--live" ]]; then
  shift
  exec "$APP_BIN" "$@"
else
  export AGY_HIGHER_SANDBOX=1
  exec "$APP_BIN" --sandbox "$@"
fi
