#!/usr/bin/env bash
set -euo pipefail

IS_SOURCED=0
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  IS_SOURCED=1
fi

usage() {
  cat <<'EOF'
Compatibility wrapper for scripts/source-install.sh.

Usage:
  bash scripts/wsl-install.sh [options...]
  source scripts/wsl-install.sh [options...]

Prefer scripts/source-install.sh for new installs.
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

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_INSTALL="${REPO_ROOT}/scripts/source-install.sh"

if [[ ! -f "${SOURCE_INSTALL}" ]]; then
  fail "Missing install helper: ${SOURCE_INSTALL}"
fi

if [[ "${IS_SOURCED}" -eq 1 ]]; then
  source "${SOURCE_INSTALL}" "$@"
else
  bash "${SOURCE_INSTALL}" "$@"
fi
