#!/usr/bin/env bash
set -euo pipefail

IS_SOURCED=0
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  IS_SOURCED=1
fi

ZIG_VERSION_DEFAULT="0.15.1"
ZIG_INSTALL_ROOT_DEFAULT="${HOME}/.local/opt"
ZIG_BIN_DIR_DEFAULT="${HOME}/.local/bin"
ZIG_DOWNLOAD_BASE_URL_DEFAULT="https://ziglang.org/download"

usage() {
  cat <<'EOF'
Ensure Zig is available, then build and install codex-auth from the current source checkout.

Usage:
  bash scripts/source-install.sh [source-install options...] [dev-install options...]
  source scripts/source-install.sh [source-install options...] [dev-install options...]

Source-install options:
  --zig-version <version>       Zig version to install when missing (default: 0.15.1)
  --zig-install-root <dir>      Root directory for Zig installs (default: $HOME/.local/opt)
  --zig-bin-dir <dir>           Directory for the zig launcher symlink (default: $HOME/.local/bin)
  --zig-download-base-url <url> Base download URL for Zig archives
  -h, --help                    Show help

All other options are forwarded to scripts/dev-install.sh.

Examples:
  bash scripts/source-install.sh
  source scripts/source-install.sh --install-dir "$HOME/.local/bin"
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

prepend_path() {
  local dir="$1"
  if ! path_contains_dir "${dir}"; then
    export PATH="${dir}:${PATH}"
  fi
}

detect_zig_archive() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"

  case "${os}" in
    Linux)
      case "${arch}" in
        x86_64|amd64) printf "zig-x86_64-linux-%s.tar.xz" "${ZIG_VERSION}" ;;
        aarch64|arm64) printf "zig-aarch64-linux-%s.tar.xz" "${ZIG_VERSION}" ;;
        armv7l|armv7) printf "zig-arm-linux-%s.tar.xz" "${ZIG_VERSION}" ;;
        riscv64) printf "zig-riscv64-linux-%s.tar.xz" "${ZIG_VERSION}" ;;
        *)
          return 1
          ;;
      esac
      ;;
    Darwin)
      case "${arch}" in
        x86_64|amd64) printf "zig-x86_64-macos-%s.tar.xz" "${ZIG_VERSION}" ;;
        aarch64|arm64) printf "zig-aarch64-macos-%s.tar.xz" "${ZIG_VERSION}" ;;
        *)
          return 1
          ;;
      esac
      ;;
    *)
      return 1
      ;;
  esac
}

download_file() {
  local url="$1"
  local dest="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fL "${url}" -o "${dest}"
    return
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -O "${dest}" "${url}"
    return
  fi

  fail "curl or wget is required to install Zig automatically."
}

ensure_zig() {
  if command -v zig >/dev/null 2>&1; then
    local version
    version="$(zig version 2>/dev/null || true)"
    if [[ -n "${version}" ]]; then
      print_info "Using existing zig ${version} from $(command -v zig)"
      if [[ "${version}" != "${ZIG_VERSION}" ]]; then
        print_warn "Expected Zig ${ZIG_VERSION}, but found ${version}. Continuing with the existing zig."
      fi
    else
      print_info "Using existing zig from $(command -v zig)"
    fi
    return
  fi

  if ! command -v tar >/dev/null 2>&1; then
    fail "tar is required to install Zig automatically."
  fi

  local archive_name archive_url install_dir symlink_path temp_dir archive_path
  archive_name="$(detect_zig_archive)" || fail "Automatic Zig installation is not supported on $(uname -s)/$(uname -m)."
  archive_url="${ZIG_DOWNLOAD_BASE_URL}/${ZIG_VERSION}/${archive_name}"
  install_dir="${ZIG_INSTALL_ROOT}/${archive_name%.tar.xz}"
  symlink_path="${ZIG_BIN_DIR}/zig"

  if [[ ! -x "${install_dir}/zig" ]]; then
    temp_dir="$(mktemp -d)"
    archive_path="${temp_dir}/${archive_name}"
    print_info "Downloading Zig ${ZIG_VERSION} from ${archive_url}"
    download_file "${archive_url}" "${archive_path}"
    mkdir -p "${ZIG_INSTALL_ROOT}"
    tar -xf "${archive_path}" -C "${ZIG_INSTALL_ROOT}"
    rm -rf "${temp_dir}"
  else
    print_info "Reusing downloaded Zig ${ZIG_VERSION} from ${install_dir}"
  fi

  mkdir -p "${ZIG_BIN_DIR}"
  ln -sfn "${install_dir}/zig" "${symlink_path}"
  prepend_path "${ZIG_BIN_DIR}"

  if ! command -v zig >/dev/null 2>&1; then
    fail "Failed to make zig available on PATH after installation."
  fi

  print_success "Installed Zig $(zig version) at ${install_dir}"
}

ZIG_VERSION="${ZIG_VERSION_DEFAULT}"
ZIG_INSTALL_ROOT="${ZIG_INSTALL_ROOT_DEFAULT}"
ZIG_BIN_DIR="${ZIG_BIN_DIR_DEFAULT}"
ZIG_DOWNLOAD_BASE_URL="${ZIG_DOWNLOAD_BASE_URL_DEFAULT}"
DEV_INSTALL_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --zig-version)
      [[ $# -ge 2 ]] || fail "Missing value for --zig-version."
      ZIG_VERSION="$2"
      shift 2
      ;;
    --zig-install-root)
      [[ $# -ge 2 ]] || fail "Missing value for --zig-install-root."
      ZIG_INSTALL_ROOT="$2"
      shift 2
      ;;
    --zig-bin-dir)
      [[ $# -ge 2 ]] || fail "Missing value for --zig-bin-dir."
      ZIG_BIN_DIR="$2"
      shift 2
      ;;
    --zig-download-base-url)
      [[ $# -ge 2 ]] || fail "Missing value for --zig-download-base-url."
      ZIG_DOWNLOAD_BASE_URL="$2"
      shift 2
      ;;
    -h|--help)
      usage
      finish 0
      ;;
    *)
      DEV_INSTALL_ARGS+=("$1")
      shift
      ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV_INSTALL="${REPO_ROOT}/scripts/dev-install.sh"

if [[ ! -f "${DEV_INSTALL}" ]]; then
  fail "Missing install helper: ${DEV_INSTALL}"
fi

ensure_zig

if [[ "${IS_SOURCED}" -eq 1 ]]; then
  export CODEX_AUTH_INSTALL_SOURCE_HINT="scripts/source-install.sh"
  source "${DEV_INSTALL}" "${DEV_INSTALL_ARGS[@]}"
else
  CODEX_AUTH_INSTALL_SOURCE_HINT="scripts/source-install.sh" bash "${DEV_INSTALL}" "${DEV_INSTALL_ARGS[@]}"
fi
