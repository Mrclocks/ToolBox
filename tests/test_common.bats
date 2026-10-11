#!/usr/bin/env bats
# shellcheck shell=bats

load helpers

@test "is_port accepts valid ports" {
  run is_port 22
  [ "$status" -eq 0 ]
  run is_port 65535
  [ "$status" -eq 0 ]
}

@test "is_port rejects invalid ports" {
  run is_port 0
  [ "$status" -ne 0 ]
  run is_port 65536
  [ "$status" -ne 0 ]
  run is_port abc
  [ "$status" -ne 0 ]
}

@test "is_port_spec accepts ranges" {
  run is_port_spec "1000:2000"
  [ "$status" -eq 0 ]
  run is_port_spec "2000:1000"
  [ "$status" -ne 0 ]
}

@test "is_ipv4 rejects leading zeros" {
  run is_ipv4 "1.2.3.4"
  [ "$status" -eq 0 ]
  run is_ipv4 "08.1.1.1"
  [ "$status" -ne 0 ]
  run is_ipv4 "1.02.3.4"
  [ "$status" -ne 0 ]
  run is_ipv4 "0.0.0.0"
  [ "$status" -eq 0 ]
}

@test "is_ipv4 rejects out of range" {
  run is_ipv4 "256.1.1.1"
  [ "$status" -ne 0 ]
}

@test "trim strips whitespace" {
  result="$(trim '  hello  ')"
  [ "$result" = "hello" ]
}

@test "is_true recognizes yes variants" {
  run is_true yes
  [ "$status" -eq 0 ]
  run is_true YES
  [ "$status" -eq 0 ]
  run is_true no
  [ "$status" -ne 0 ]
}

@test "answered_yes is strict" {
  declare -gA SECUREBOX_ANSWERS=()
  SECUREBOX_ANSWERS[foo]=yes
  run answered_yes foo
  [ "$status" -eq 0 ]
  SECUREBOX_ANSWERS[foo]=no
  run answered_yes foo
  [ "$status" -ne 0 ]
  unset 'SECUREBOX_ANSWERS[foo]'
  run answered_yes foo
  [ "$status" -ne 0 ]
}
