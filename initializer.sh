#!/usr/bin/env bash
set -euo pipefail

DEFAULT_RAW_BASE="https://raw.githubusercontent.com/Recamm/Project-Initializer/main"
RAW_BASE="${INIT_RAW_BASE:-$DEFAULT_RAW_BASE}"

PS_BIN=""

resolve_ps_bin() {
  if command -v pwsh >/dev/null 2>&1; then
    PS_BIN="pwsh"
    return 0
  fi

  if command -v powershell.exe >/dev/null 2>&1; then
    PS_BIN="powershell.exe"
    return 0
  fi

  echo "Falta prerequisito: PowerShell (pwsh o powershell.exe)" >&2
  exit 1
}

# Compatible con ejecucion desde archivo y por stdin (bash -s).
SOURCE_PATH="${BASH_SOURCE[0]-$0}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SOURCE_PATH")" && pwd)"
PS_SCRIPT="$SCRIPT_DIR/initializer.ps1"
CONFIG_FILE="$SCRIPT_DIR/initializer.config.json"

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Falta prerequisito: $cmd" >&2
    exit 1
  fi
}

run_local() {
  resolve_ps_bin
  "$PS_BIN" -NoProfile -File "$PS_SCRIPT" -ConfigPath "$CONFIG_FILE" "$@"
}

run_remote() {
  resolve_ps_bin
  require_cmd curl

  local tmp_dir
  tmp_dir="$(mktemp -d 2>/dev/null || mktemp -d -t initializer.XXXXXX)"

  cleanup() {
    rm -rf "$tmp_dir"
  }
  trap cleanup EXIT

  curl -fsSL "$RAW_BASE/initializer.ps1" -o "$tmp_dir/initializer.ps1"
  curl -fsSL "$RAW_BASE/initializer.config.json" -o "$tmp_dir/initializer.config.json"

  "$PS_BIN" -NoProfile -File "$tmp_dir/initializer.ps1" -ConfigPath "$tmp_dir/initializer.config.json" "$@"
}

MODE="auto"
if [[ "${1:-}" == "--remote" ]]; then
  MODE="remote"
  shift
elif [[ "${1:-}" == "--local" ]]; then
  MODE="local"
  shift
fi

if [[ "$MODE" == "local" ]]; then
  run_local "$@"
  exit $?
fi

if [[ "$MODE" == "remote" ]]; then
  run_remote "$@"
  exit $?
fi

if [[ -f "$PS_SCRIPT" && -f "$CONFIG_FILE" ]]; then
  run_local "$@"
else
  run_remote "$@"
fi
