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

@test "sourcing verify.sh does not execute the main checks" {
  run bash -c "source '$REPO_ROOT/scripts/verify.sh'; echo sourced-ok"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sourced-ok"* ]]
  [[ "$output" != *"Verifikasi mail server"* ]]
}

# --- smtp_relay_verdict: classifies the isolated RCPT TO response ---

@test "smtp_relay_verdict flags Stalwart's real accept string as OPEN_RELAY" {
  run bash -c "source '$REPO_ROOT/scripts/verify.sh'; smtp_relay_verdict '250 2.1.5 OK'"
  [ "$status" -eq 1 ]
  [ "$output" = "OPEN_RELAY" ]
}

@test "smtp_relay_verdict flags any other 2xx RCPT response as OPEN_RELAY" {
  run bash -c "source '$REPO_ROOT/scripts/verify.sh'; smtp_relay_verdict '250 Accepted'"
  [ "$status" -eq 1 ]
  [ "$output" = "OPEN_RELAY" ]
}

@test "smtp_relay_verdict treats a 550 refusal as SAFE" {
  run bash -c "source '$REPO_ROOT/scripts/verify.sh'; smtp_relay_verdict '550 5.7.1 Relay not permitted'"
  [ "$status" -eq 0 ]
  [ "$output" = "SAFE" ]
}

@test "smtp_relay_verdict treats empty input as INCONCLUSIVE and fails" {
  run bash -c "source '$REPO_ROOT/scripts/verify.sh'; smtp_relay_verdict ''"
  [ "$status" -eq 1 ]
  [ "$output" = "INCONCLUSIVE" ]
}

@test "smtp_relay_verdict with no argument (missing tool case) is INCONCLUSIVE and fails" {
  run bash -c "source '$REPO_ROOT/scripts/verify.sh'; smtp_relay_verdict"
  [ "$status" -eq 1 ]
  [ "$output" = "INCONCLUSIVE" ]
}

# --- imap_login_verdict: must look only at the LOGIN tag's response ---

@test "imap_login_verdict passes when the LOGIN tag itself is OK" {
  transcript=$'a1 OK LOGIN completed\na2 OK LOGOUT completed'
  run bash -c "source '$REPO_ROOT/scripts/verify.sh'; imap_login_verdict \"\$1\"" _ "$transcript"
  [ "$status" -eq 0 ]
  [ "$output" = "LOGIN_OK" ]
}

@test "imap_login_verdict fails a rejected login even though LOGOUT reports OK" {
  transcript=$'a1 NO [AUTHENTICATIONFAILED] Authentication failed\na2 OK LOGOUT completed'
  run bash -c "source '$REPO_ROOT/scripts/verify.sh'; imap_login_verdict \"\$1\"" _ "$transcript"
  [ "$status" -eq 1 ]
  [ "$output" = "LOGIN_FAILED" ]
}

@test "imap_login_verdict treats empty transcript as INCONCLUSIVE and fails" {
  run bash -c "source '$REPO_ROOT/scripts/verify.sh'; imap_login_verdict ''"
  [ "$status" -eq 1 ]
  [ "$output" = "INCONCLUSIVE" ]
}

@test "verify.sh uses distinct tags for IMAP LOGIN and LOGOUT" {
  grep -q 'a1 LOGIN' "$REPO_ROOT/scripts/verify.sh"
  grep -q 'a2 LOGOUT' "$REPO_ROOT/scripts/verify.sh"
}

@test "verify.sh never echoes the IMAP password" {
  run grep -n 'echo.*MAIL_USER_1_PASS\|printf.*MAIL_USER_1_PASS' "$REPO_ROOT/scripts/verify.sh"
  [ "$status" -ne 0 ]
}

@test "verify.sh checks nc and dig are installed before using them" {
  grep -q "command -v nc" "$REPO_ROOT/scripts/verify.sh"
  grep -q "command -v dig" "$REPO_ROOT/scripts/verify.sh"
}

@test "verify.sh mentions NAT hairpin as a possible cause of false failures" {
  run grep -qi 'hairpin' "$REPO_ROOT/scripts/verify.sh"
  [ "$status" -eq 0 ]
}

@test "verify.sh tells the operator the open-relay probe must be confirmed off-box" {
  run grep -qi 'mxtoolbox\|luar jaringan\|di luar' "$REPO_ROOT/scripts/verify.sh"
  [ "$status" -eq 0 ]
}

@test "verify.sh raises the memory warning threshold above 85 to avoid page-cache false alarms" {
  run grep -q -- '-lt 95' "$REPO_ROOT/scripts/verify.sh"
  [ "$status" -eq 0 ]
  run grep -q -- '-lt 85' "$REPO_ROOT/scripts/verify.sh"
  [ "$status" -ne 0 ]
}
