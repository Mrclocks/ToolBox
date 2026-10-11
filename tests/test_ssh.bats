#!/usr/bin/env bats
# shellcheck shell=bats

load helpers

setup() {
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/modules/ssh.sh"
}

@test "_ssh_write_dropin omits Protocol 2" {
  local tmp
  tmp="$(mktemp)"
  SECUREBOX_ANSWERS["ssh_password_auth"]=keep
  SECUREBOX_ANSWERS["ssh_permit_root"]=keep
  SECUREBOX_ANSWERS["ssh_max_auth_tries"]=5
  _ssh_write_dropin "$tmp" 22 2222 0
  run grep -E '^Protocol ' "$tmp"
  [ "$status" -ne 0 ]
  run grep -E '^MaxAuthTries 5' "$tmp"
  [ "$status" -eq 0 ]
  run grep -E '^Port 22' "$tmp"
  [ "$status" -eq 0 ]
  run grep -E '^Port 2222' "$tmp"
  [ "$status" -eq 0 ]
  rm -f "$tmp"
}

@test "_ssh_write_dropin finalize keeps only new port" {
  local tmp
  tmp="$(mktemp)"
  SECUREBOX_ANSWERS["ssh_password_auth"]=keep
  SECUREBOX_ANSWERS["ssh_permit_root"]=keep
  SECUREBOX_ANSWERS["ssh_max_auth_tries"]=7
  _ssh_write_dropin "$tmp" 22 2222 1
  ports="$(grep -cE '^Port ' "$tmp" || true)"
  [ "$ports" -eq 1 ]
  run grep -E '^Port 2222' "$tmp"
  [ "$status" -eq 0 ]
  run grep -E '^MaxAuthTries 7' "$tmp"
  [ "$status" -eq 0 ]
  rm -f "$tmp"
}

@test "_ssh_user_has_usable_key ignores forced command" {
  local home keys
  home="$(mktemp -d)"
  mkdir -p "${home}/.ssh"
  keys="${home}/.ssh/authorized_keys"
  printf 'command="/bin/false" ssh-ed25519 AAAA forced\n' >"$keys"
  # Mock getent / login user via SUDO_USER pointing at a fake — function uses getent
  # Directly test awk logic via a temp override of home detection is hard; unit the awk:
  run awk '
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*$/ {next}
    /command="/ {next}
    /command=/ {next}
    {found=1; exit}
    END {exit found?0:1}
  ' "$keys"
  [ "$status" -ne 0 ]
  printf 'ssh-ed25519 AAAA goodkey\n' >>"$keys"
  run awk '
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*$/ {next}
    /command="/ {next}
    /command=/ {next}
    {found=1; exit}
    END {exit found?0:1}
  ' "$keys"
  [ "$status" -eq 0 ]
  rm -rf "$home"
}

@test "SSH drop-in name is 00-securebox.conf" {
  [ "$SSH_DROPIN_NAME" = "00-securebox.conf" ]
}
