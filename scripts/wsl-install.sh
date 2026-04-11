#!/usr/bin/env bash
set -euo pipefail

IS_SOURCED=0
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  IS_SOURCED=1
fi

usage() {
  cat <<'EOF'
Build and install codex-auth from the current source checkout for WSL/Linux.

Usage:
  bash scripts/wsl-install.sh [dev-install options...]
  source scripts/wsl-install.sh [dev-install options...]

Examples:
  bash scripts/wsl-install.sh
  source scripts/wsl-install.sh --install-dir "$HOME/.local/bin"

Notes:
  - Run this script inside your WSL/Linux checkout.
  - It delegates to scripts/dev-install.sh to build from source in the current repo.
EOF
}

finish() {
  local code="$1"
  if [[ "${IS_SOURCED}" -eq 1 ]]; then
    return "${code}"
  fi
  exit "${code}"
}

fail() {
  echo "$*" >&2
  finish 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  finish 0
fi

if [[ "$(uname -s)" != "Linux" ]]; then
  fail "scripts/wsl-install.sh must be run from a Linux environment such as WSL."
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV_INSTALL="${REPO_ROOT}/scripts/dev-install.sh"

if [[ ! -f "${DEV_INSTALL}" ]]; then
  fail "Missing install helper: ${DEV_INSTALL}"
fi

if [[ "${IS_SOURCED}" -eq 1 ]]; then
  # Preserve the caller's shell environment when sourced.
  export CODEX_AUTH_INSTALL_SOURCE_HINT="scripts/wsl-install.sh"
  source "${DEV_INSTALL}" "$@"
else
  CODEX_AUTH_INSTALL_SOURCE_HINT="scripts/wsl-install.sh" bash "${DEV_INSTALL}" "$@"
fi
