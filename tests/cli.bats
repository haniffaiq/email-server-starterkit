#!/usr/bin/env bats
#
# Unit tests for scripts/lib/cli.sh (the swcli wrapper), sourced directly so
# each test can stub `stalwart-cli` on PATH and inspect swcli's behavior in
# isolation from dns-records.sh (which tests/dns.bats already covers
# end-to-end for the DKIM-printing path).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$BATS_TEST_TMPDIR"
  mkdir -p "$TMP/bin"
}

@test "swcli passes admin credentials via environment, never on argv" {
  cat > "$TMP/bin/stalwart-cli" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$ARGV_CAPTURE"
env | grep -E '^STALWART_(URL|USER|PASSWORD)=' | sort > "$ENV_CAPTURE"
exit 0
STUB
  chmod +x "$TMP/bin/stalwart-cli"

  run bash -c "
    export PATH='$TMP/bin':\$PATH
    export ARGV_CAPTURE='$TMP/argv.txt'
    export ENV_CAPTURE='$TMP/env.txt'
    export STALWART_ADMIN_PASS='supersecretpassword'
    export STALWART_URL='http://127.0.0.1:8080'
    source '$REPO_ROOT/scripts/lib/cli.sh'
    swcli query DkimSignature --json --verbose
  "
  [ "$status" -eq 0 ]

  argv="$(cat "$TMP/argv.txt")"
  [[ "$argv" == *"query"* ]]
  [[ "$argv" != *"supersecretpassword"* ]]
  [[ "$argv" != *"--password"* ]]

  envcap="$(cat "$TMP/env.txt")"
  [[ "$envcap" == *"STALWART_USER=admin"* ]]
  [[ "$envcap" == *"STALWART_PASSWORD=supersecretpassword"* ]]
  [[ "$envcap" == *"STALWART_URL="* ]]

  # And the wrapper's own combined output never leaks the password either.
  [[ "$output" != *"supersecretpassword"* ]]
}

@test "swcli passes through exit code 0 unchanged" {
  cat > "$TMP/bin/stalwart-cli" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$TMP/bin/stalwart-cli"

  run bash -c "
    export PATH='$TMP/bin':\$PATH
    export STALWART_ADMIN_PASS='x'
    source '$REPO_ROOT/scripts/lib/cli.sh'
    swcli whatever
  "
  [ "$status" -eq 0 ]
}

@test "swcli passes through several non-zero exit codes unchanged" {
  for code in 1 2 42 130; do
    cat > "$TMP/bin/stalwart-cli" <<STUB
#!/usr/bin/env bash
exit $code
STUB
    chmod +x "$TMP/bin/stalwart-cli"

    run bash -c "
      export PATH='$TMP/bin':\$PATH
      export STALWART_ADMIN_PASS='x'
      source '$REPO_ROOT/scripts/lib/cli.sh'
      swcli whatever
    "
    [ "$status" -eq "$code" ]
  done
}

@test "stderr produced by the wrapped CLI reaches the caller's stderr" {
  cat > "$TMP/bin/stalwart-cli" <<'STUB'
#!/usr/bin/env bash
echo "peringatan dari stalwart-cli: cache lambat" >&2
exit 0
STUB
  chmod +x "$TMP/bin/stalwart-cli"

  run bash -c "
    export PATH='$TMP/bin':\$PATH
    export STALWART_ADMIN_PASS='x'
    source '$REPO_ROOT/scripts/lib/cli.sh'
    swcli whatever
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"peringatan dari stalwart-cli: cache lambat"* ]]
}

@test "auth hint appears on a non-zero exit with '401 Unauthorized' stderr" {
  cat > "$TMP/bin/stalwart-cli" <<'STUB'
#!/usr/bin/env bash
echo "Error: 401 Unauthorized" >&2
exit 1
STUB
  chmod +x "$TMP/bin/stalwart-cli"

  run bash -c "
    export PATH='$TMP/bin':\$PATH
    export STALWART_ADMIN_PASS='x'
    source '$REPO_ROOT/scripts/lib/cli.sh'
    swcli whatever
  "
  [ "$status" -eq 1 ]
  [[ "$output" == *"autentikasi"* ]]
  [[ "$output" == *"401 Unauthorized"* ]]
}

@test "auth hint appears on a non-zero exit with 'authentication failed' stderr" {
  cat > "$TMP/bin/stalwart-cli" <<'STUB'
#!/usr/bin/env bash
echo "authentication failed for user admin" >&2
exit 1
STUB
  chmod +x "$TMP/bin/stalwart-cli"

  run bash -c "
    export PATH='$TMP/bin':\$PATH
    export STALWART_ADMIN_PASS='x'
    source '$REPO_ROOT/scripts/lib/cli.sh'
    swcli whatever
  "
  [ "$status" -eq 1 ]
  [[ "$output" == *"autentikasi"* ]]
}

@test "auth hint does NOT appear on a non-zero exit with unrelated stderr" {
  cat > "$TMP/bin/stalwart-cli" <<'STUB'
#!/usr/bin/env bash
echo "connection refused: could not reach 127.0.0.1:8080" >&2
exit 1
STUB
  chmod +x "$TMP/bin/stalwart-cli"

  run bash -c "
    export PATH='$TMP/bin':\$PATH
    export STALWART_ADMIN_PASS='x'
    source '$REPO_ROOT/scripts/lib/cli.sh'
    swcli whatever
  "
  [ "$status" -eq 1 ]
  [[ "$output" != *"autentikasi"* ]]
  [[ "$output" == *"connection refused"* ]]
}

@test "auth hint does NOT appear on a successful (exit 0) call even if stderr mentions auth words" {
  cat > "$TMP/bin/stalwart-cli" <<'STUB'
#!/usr/bin/env bash
echo "note: authentication cache refreshed" >&2
exit 0
STUB
  chmod +x "$TMP/bin/stalwart-cli"

  run bash -c "
    export PATH='$TMP/bin':\$PATH
    export STALWART_ADMIN_PASS='x'
    source '$REPO_ROOT/scripts/lib/cli.sh'
    swcli whatever
  "
  [ "$status" -eq 0 ]
  [[ "$output" != *"autentikasi ke stalwart-cli gagal"* ]]
}

@test "swcli streams stderr through as it is produced, instead of withholding it until the process exits" {
  # The stub writes a marker to stderr, then sleeps well past our poll
  # window before exiting. If stderr were buffered until exit (the old
  # `2>"$errfile"` ... `cat "$errfile" >&2` behavior), the marker would not
  # be observable in the output file until after the sleep completes. With
  # streaming (`tee` piped straight to the real stderr), it should show up
  # almost immediately.
  cat > "$TMP/bin/stalwart-cli" <<'STUB'
#!/usr/bin/env bash
echo "streaming-marker" >&2
sleep 3
exit 0
STUB
  chmod +x "$TMP/bin/stalwart-cli"

  outfile="$TMP/out.txt"
  bash -c "
    export PATH='$TMP/bin':\$PATH
    export STALWART_ADMIN_PASS='x'
    source '$REPO_ROOT/scripts/lib/cli.sh'
    swcli whatever
  " >"$outfile" 2>&1 &
  bg_pid=$!

  found=0
  # Poll for up to ~2s, comfortably inside the stub's 3s sleep, so a pass
  # here can only happen if the marker arrived before the process exited.
  for _ in $(seq 1 40); do
    if grep -q "streaming-marker" "$outfile" 2>/dev/null; then
      found=1
      break
    fi
    sleep 0.05
  done

  wait "$bg_pid"
  [ "$found" -eq 1 ]
}
