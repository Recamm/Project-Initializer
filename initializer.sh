#!/usr/bin/env bash
set -euo pipefail

DEFAULT_RAW_BASE="https://raw.githubusercontent.com/Recamm/Project-Initializer/main"
RAW_BASE="${INIT_RAW_BASE:-$DEFAULT_RAW_BASE}"
INIT_REPO="${INIT_REPO:-Recamm/Project-Initializer}"
INIT_REF="${INIT_REF:-main}"
TMP_DIR=""

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

resolve_local_paths() {
  local source_path="${BASH_SOURCE[0]:-${0:-}}"
  local script_dir=""

  # En bash -s no hay ruta de archivo. En ese caso no hay modo local posible.
  if [[ -n "$source_path" && "$source_path" != "-" && "$source_path" != "bash" ]]; then
    script_dir="$(cd -- "$(dirname -- "$source_path")" && pwd)"
  fi

  if [[ -z "$script_dir" ]]; then
    echo "No se pudo resolver ruta local del script. Usa --remote o ejecuta initializer.sh como archivo." >&2
    return 1
  fi

  PS_SCRIPT="$script_dir/initializer.ps1"
  CONFIG_FILE="$script_dir/initializer.config.json"
  return 0
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Falta prerequisito: $cmd" >&2
    exit 1
  fi
}

run_local() {
  local PS_SCRIPT=""
  local CONFIG_FILE=""

  resolve_local_paths
  resolve_ps_bin
  "$PS_BIN" -NoProfile -File "$PS_SCRIPT" -ConfigPath "$CONFIG_FILE" "$@"
}

run_remote() {
  resolve_ps_bin
  require_cmd curl

  download_file() {
    local file_name="$1"
    local out_file="$2"

    if curl -fsSL "$RAW_BASE/$file_name" -o "$out_file"; then
      return 0
    fi

    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
      curl -fsSL \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.raw+json" \
        "https://api.github.com/repos/$INIT_REPO/contents/$file_name?ref=$INIT_REF" \
        -o "$out_file"
      return 0
    fi

    echo "No se pudo descargar $file_name desde raw. Si el repo es privado, define GITHUB_TOKEN e intenta de nuevo." >&2
    return 1
  }

  TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t initializer.XXXXXX)"

  cleanup() {
    if [[ -n "${TMP_DIR:-}" ]]; then
      rm -rf "$TMP_DIR"
    fi
  }
  trap cleanup EXIT

  download_file "initializer.ps1" "$TMP_DIR/initializer.ps1"
  download_file "initializer.config.json" "$TMP_DIR/initializer.config.json"

  "$PS_BIN" -NoProfile -File "$TMP_DIR/initializer.ps1" -ConfigPath "$TMP_DIR/initializer.config.json" "$@"
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

if resolve_local_paths >/dev/null 2>&1; then
  run_local "$@"
else
  run_remote "$@"
fi
