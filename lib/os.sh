#!/usr/bin/env bash
# SecureBox — OS detection
# shellcheck shell=bash

OS_ID=""
OS_VERSION_ID=""
OS_VERSION_CODENAME=""
OS_PRETTY=""
OS_FAMILY=""
OS_SUPPORTED=0

detect_os() {
  if [[ ! -r /etc/os-release ]]; then
    ui_error "Cannot read /etc/os-release"
    return 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_VERSION_ID="${VERSION_ID:-}"
  OS_VERSION_CODENAME="${VERSION_CODENAME:-}"
  OS_PRETTY="${PRETTY_NAME:-$OS_ID $OS_VERSION_ID}"

  case "$OS_ID" in
    ubuntu) OS_FAMILY="debian" ;;
    debian) OS_FAMILY="debian" ;;
    *)
      OS_FAMILY="$OS_ID"
      OS_SUPPORTED=0
      return 0
      ;;
  esac

  local major="${OS_VERSION_ID%%.*}"
  case "$OS_ID" in
    ubuntu)
      if (( major >= 22 && major <= 26 )); then
        OS_SUPPORTED=1
      fi
      ;;
    debian)
      if (( major == 12 || major == 13 )); then
        OS_SUPPORTED=1
      fi
      ;;
  esac
}

assert_supported_os() {
  detect_os || exit 1
  if [[ "$OS_SUPPORTED" -ne 1 ]]; then
    ui_error "Unsupported OS: ${OS_PRETTY}"
    ui_info  "Supported: Ubuntu 22–26 and Debian 12–13."
    exit 1
  fi
  ui_success "Detected supported OS: ${OS_PRETTY}"
}
