#!/usr/bin/env bash
set -euo pipefail

IS_SOURCED=0
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  IS_SOURCED=1
fi

usage() {
  cat <<'EOF'
Build and install codex-auth from the current source checkout.

Usage:
  bash scripts/dev-install.sh [--install-dir <dir>] [--optimize <mode>] [--no-add-to-path]
  source scripts/dev-install.sh [--install-dir <dir>] [--optimize <mode>] [--no-add-to-path]

Options:
  --install-dir <dir>  Install directory for binaries (default: $HOME/.local/bin)
  --optimize <mode>    Zig optimize mode (default: ReleaseSafe)
  --add-to-path        Persist install dir to shell profile (default behavior)
  --no-add-to-path     Skip persisting install dir to shell profile
  -h, --help           Show help

Notes:
  - Running with 'source' also updates PATH in the current shell immediately.
  - Running with 'bash' installs for future shells and updates the shell profile when needed.
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

INSTALL_DIR="${HOME}/.local/bin"
OPTIMIZE="ReleaseSafe"
ADD_TO_PATH=1
SHELL_NAME="$(basename "${SHELL:-bash}")"
PROFILE_FILE=""
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'
else
  C_RESET=""
  C_BOLD=""
  C_GREEN=""
  C_YELLOW=""
  C_CYAN=""
fi

print_color() {
  local color="$1"
  shift
  printf "%b\n" "${color}$*${C_RESET}"
}

print_success() {
  print_color "${C_BOLD}${C_GREEN}" "$*"
}

print_warn() {
  print_color "${C_BOLD}${C_YELLOW}" "$*"
}

print_info() {
  print_color "${C_CYAN}" "$*"
}

print_cmd() {
  print_color "${C_BOLD}${C_CYAN}" "$*"
}

normalize_path_entry() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  if [[ "${value}" == "/" ]]; then
    printf "/"
    return
  fi
  while [[ "${value}" == */ && "${value}" != "/" ]]; do
    value="${value%/}"
  done
  printf "%s" "${value}"
}

path_contains_dir() {
  local target normalized_target
  target="${1}"
  normalized_target="$(normalize_path_entry "${target}")"
  IFS=':' read -r -a _segments <<< "${PATH:-}"
  for segment in "${_segments[@]}"; do
    if [[ "$(normalize_path_entry "${segment}")" == "${normalized_target}" ]]; then
      return 0
    fi
  done
  return 1
}

detect_profile_file() {
  local candidate

  if [[ "${SHELL_NAME}" == "fish" ]]; then
    printf "%s" "${HOME}/.config/fish/config.fish"
    return
  fi

  if [[ "${SHELL_NAME}" == "zsh" ]]; then
    for candidate in "${HOME}/.zshrc" "${HOME}/.zprofile" "${HOME}/.profile"; do
      if [[ -f "${candidate}" ]]; then
        printf "%s" "${candidate}"
        return
      fi
    done
    printf "%s" "${HOME}/.zshrc"
    return
  fi

  for candidate in "${HOME}/.bashrc" "${HOME}/.bash_profile" "${HOME}/.profile"; do
    if [[ -f "${candidate}" ]]; then
      printf "%s" "${candidate}"
      return
    fi
  done
  printf "%s" "${HOME}/.bashrc"
}

persist_path_to_profile() {
  local profile path_line
  profile="$(detect_profile_file)"
  PROFILE_FILE="${profile}"
  mkdir -p "$(dirname "${profile}")"
  touch "${profile}"

  if grep -Fq "${INSTALL_DIR}" "${profile}"; then
    return
  fi

  if [[ "${SHELL_NAME}" == "fish" ]]; then
    {
      echo ""
      echo "# Added by codex-auth installer"
      echo "if not contains -- \"${INSTALL_DIR}\" \$PATH"
      echo "    set -gx PATH \"${INSTALL_DIR}\" \$PATH"
      echo "end"
    } >> "${profile}"
  else
    path_line="export PATH=\"${INSTALL_DIR}:\$PATH\""
    {
      echo ""
      echo "# Added by codex-auth installer"
      echo "${path_line}"
    } >> "${profile}"
  fi
}

activate_path_now() {
  if path_contains_dir "${INSTALL_DIR}"; then
    return
  fi
  export PATH="${INSTALL_DIR}:${PATH}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir)
      [[ $# -ge 2 ]] || fail "Missing value for --install-dir."
      INSTALL_DIR="$2"
      shift 2
      ;;
    --optimize)
      [[ $# -ge 2 ]] || fail "Missing value for --optimize."
      OPTIMIZE="$2"
      shift 2
      ;;
    --add-to-path)
      ADD_TO_PATH=1
      shift
      ;;
    --no-add-to-path)
      ADD_TO_PATH=0
      shift
      ;;
    -h|--help)
      usage
      finish 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
done

if ! command -v zig >/dev/null 2>&1; then
  fail "zig is required."
fi

print_info "Building codex-auth from ${REPO_ROOT}"
(cd "${REPO_ROOT}" && zig build -Doptimize="${OPTIMIZE}")

BIN_SRC="${REPO_ROOT}/zig-out/bin/codex-auth"
AUTO_SRC="${REPO_ROOT}/zig-out/bin/codex-auth-auto"

if [[ ! -f "${BIN_SRC}" ]]; then
  fail "Build succeeded, but ${BIN_SRC} was not found."
fi

mkdir -p "${INSTALL_DIR}"

if command -v install >/dev/null 2>&1; then
  install -m 0755 "${BIN_SRC}" "${INSTALL_DIR}/codex-auth"
  if [[ -f "${AUTO_SRC}" ]]; then
    install -m 0755 "${AUTO_SRC}" "${INSTALL_DIR}/codex-auth-auto"
  fi
else
  cp "${BIN_SRC}" "${INSTALL_DIR}/codex-auth"
  chmod 0755 "${INSTALL_DIR}/codex-auth"
  if [[ -f "${AUTO_SRC}" ]]; then
    cp "${AUTO_SRC}" "${INSTALL_DIR}/codex-auth-auto"
    chmod 0755 "${INSTALL_DIR}/codex-auth-auto"
  fi
fi

CURRENT_PATH_MISSING=0
if ! path_contains_dir "${INSTALL_DIR}"; then
  CURRENT_PATH_MISSING=1
fi

if [[ "${ADD_TO_PATH}" -eq 1 ]]; then
  persist_path_to_profile
fi

if [[ "${IS_SOURCED}" -eq 1 ]]; then
  activate_path_now
fi

print_success "codex-auth built and installed successfully."
print_info "Binary: ${INSTALL_DIR}/codex-auth"

if command -v "${INSTALL_DIR}/codex-auth" >/dev/null 2>&1; then
  VERSION_OUTPUT="$("${INSTALL_DIR}/codex-auth" --version)"
  print_info "Version: ${VERSION_OUTPUT}"
fi

if path_contains_dir "${INSTALL_DIR}"; then
  if [[ "${IS_SOURCED}" -eq 1 ]]; then
    print_success "Ready in the current shell."
  else
    print_success "Ready in this terminal."
  fi
else
  print_warn "Not ready in the current shell yet."
  if [[ "${ADD_TO_PATH}" -eq 1 && -n "${PROFILE_FILE}" ]]; then
    print_warn "Path was added to ${PROFILE_FILE} for future shells."
  fi
  print_warn "Use codex-auth immediately in this terminal with:"
  if [[ "${SHELL_NAME}" == "fish" ]]; then
    print_cmd "  set -gx PATH \"${INSTALL_DIR}\" \$PATH"
  else
    print_cmd "  export PATH=\"${INSTALL_DIR}:\$PATH\""
  fi
  print_warn "Or source this script instead:"
  print_cmd "  source scripts/dev-install.sh"
fi

finish 0
