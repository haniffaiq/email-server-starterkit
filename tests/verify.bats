#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "verify.sh has no syntax errors" {
  run bash -n "$REPO_ROOT/scripts/verify.sh"
  [ "$status" -eq 0 ]
}

@test "verify.sh performs an explicit open-relay test" {
  run grep -c 'open.relay\|open_relay' "$REPO_ROOT/scripts/verify.sh"
  [ "$output" -gt 0 ]
}

@test "verify.sh checks inbound port 25, tls, and imap login" {
  grep -q 'port 25' "$REPO_ROOT/scripts/verify.sh"
  grep -q '993' "$REPO_ROOT/scripts/verify.sh"
  grep -q 'x509' "$REPO_ROOT/scripts/verify.sh"
}
