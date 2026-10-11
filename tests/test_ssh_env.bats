#!/usr/bin/env bats
# shellcheck shell=bats

load helpers

@test "recover_ssh_env keeps existing SSH_CONNECTION" {
  export SSH_CONNECTION="1.2.3.4 1234 5.6.7.8 22"
  recover_ssh_env
  [ "$SSH_CONNECTION" = "1.2.3.4 1234 5.6.7.8 22" ]
}

@test "recover_ssh_env does not crash when SSH_* missing under fake sudo" {
  unset SSH_CONNECTION SSH_CLIENT SSH_TTY || true
  export SUDO_USER="nobody-does-not-exist-$$"
  unset SUDO_UID || true
  # Without a real session may return 1 — must not abort the shell
  recover_ssh_env || true
}

@test "state_record overwrites stale baselines" {
  state_record ufw_was_enabled no
  [ "$(state_get ufw_was_enabled)" = "no" ]
  state_record ufw_was_enabled yes
  [ "$(state_get ufw_was_enabled)" = "yes" ]
  state_record "mtu_eth0" "1500"
  state_record "mtu_eth0" "1280"
  [ "$(state_get mtu_eth0)" = "1280" ]
}
