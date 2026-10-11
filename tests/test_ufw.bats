#!/usr/bin/env bats
# shellcheck shell=bats

load helpers

setup() {
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/modules/ufw.sh"
}

@test "_ufw_parse_port_item parses bare port" {
  _ufw_parse_port_item "443"
  [ "$_ufw_port" = "443" ]
  [ "$_ufw_proto" = "tcp" ]
}

@test "_ufw_parse_port_item parses udp" {
  _ufw_parse_port_item "51820/udp"
  [ "$_ufw_port" = "51820" ]
  [ "$_ufw_proto" = "udp" ]
}

@test "_ufw_parse_port_item parses ranges" {
  _ufw_parse_port_item "1000:2000/tcp"
  [ "$_ufw_port" = "1000:2000" ]
  [ "$_ufw_proto" = "tcp" ]
}

@test "_ufw_parse_port_item rejects garbage" {
  run _ufw_parse_port_item "notaport"
  [ "$status" -ne 0 ]
  run _ufw_parse_port_item "80/sctp"
  [ "$status" -ne 0 ]
}

@test "detect_live_ssh_ports falls back to 22" {
  # Without SSH_CONNECTION or ss sshd, should still produce a port
  unset SSH_CONNECTION || true
  run detect_live_ssh_ports
  [ "$status" -eq 0 ]
  [[ "$output" =~ [0-9]+ ]]
}
