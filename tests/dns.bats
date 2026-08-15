#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$TMP/scripts/lib"
  cp "$REPO_ROOT"/scripts/lib/*.sh "$TMP/scripts/lib/"
  cp "$REPO_ROOT/scripts/dns-records.sh" "$TMP/scripts/"
  cat > "$TMP/.env" <<'EOF'
MAIL_HOSTNAME=mail.a.com
MAIL_DOMAIN_1=a.com
MAIL_DOMAIN_2=b.com
MAIL_ADMIN_EMAIL=admin@a.com
MAIL_USER_1=hanif@a.com
MAIL_USER_1_PASS=secret1
MAIL_APP_USER=noreply@a.com
MAIL_APP_PASS=secret2
MAIL_USER_2=second@b.com
MAIL_USER_2_PASS=secret3
CF_API_TOKEN=cftoken
RESEND_API_KEY=re_key
ADMIN_ALLOW_IP=1.2.3.4
STALWART_ADMIN_PASS=adminpass
EOF
}

# All script invocations pin SERVER_IP so tests never depend on network access
# (a real run falls back to `curl ifconfig.me`, which we must not rely on here).
RUN_ENV='SERVER_IP=203.0.113.10'

@test "prints an MX record for each domain" {
  run bash -c "cd '$TMP'; $RUN_ENV bash scripts/dns-records.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"MX"*"a.com"* ]]
  [[ "$output" == *"MX"*"b.com"* ]]
}

@test "spf points at resend, not at the server itself" {
  run bash -c "cd '$TMP'; $RUN_ENV bash scripts/dns-records.sh"
  [[ "$output" == *"include:_spf.resend.com"* ]]
  [[ "$output" != *"v=spf1 mx"* ]]
}

@test "prints a dmarc record starting at p=none" {
  run bash -c "cd '$TMP'; $RUN_ENV bash scripts/dns-records.sh"
  [[ "$output" == *"v=DMARC1"* ]]
  [[ "$output" == *"p=none"* ]]
}

@test "dmarc rua points at a real mailbox (MAIL_ADMIN_EMAIL), not an unregistered dmarc@ address" {
  run bash -c "cd '$TMP'; $RUN_ENV bash scripts/dns-records.sh"
  [[ "$output" == *"rua=mailto:admin@a.com"* ]]
  [[ "$output" != *"rua=mailto:dmarc@a.com"* ]]
  [[ "$output" != *"rua=mailto:dmarc@b.com"* ]]
}

@test "never prints the cloudflare token or resend key" {
  run bash -c "cd '$TMP'; $RUN_ENV bash scripts/dns-records.sh"
  [[ "$output" != *"cftoken"* ]]
  [[ "$output" != *"re_key"* ]]
}

@test "falls back to a placeholder when SERVER_IP is empty (not just unset)" {
  # Stub curl so this exercises the "successful but empty" case deterministically,
  # instead of depending on real network reachability to ifconfig.me.
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Simulates a curl call that succeeds (exit 0) but returns no body.
exit 0
STUB
  chmod +x "$TMP/bin/curl"

  run bash -c "cd '$TMP'; PATH='$TMP/bin':\$PATH SERVER_IP='' bash scripts/dns-records.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<IP_SERVER>"* ]]
}

@test "dkim section shows the public key and never the private key" {
  # Stub stalwart-cli so the DKIM branch actually runs in this test, instead
  # of silently no-op'ing because the real binary isn't installed. This stub
  # must satisfy the `swcli` wrapper in scripts/lib/cli.sh, which invokes
  # `stalwart-cli query DkimSignature --json` with credentials passed via
  # the STALWART_URL / STALWART_USER / STALWART_PASSWORD environment
  # variables, not as --url/--user/--password argv flags.
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/stalwart-cli" <<'STUB'
#!/usr/bin/env bash
# Fixed DkimSignature payload, modeled after a real Stalwart response: it
# carries both the public key (belongs in DNS) and the private key (must
# never be printed by dns-records.sh).
cat <<'JSON'
[
  {
    "id": "dkim-1",
    "domain": "a.com",
    "selector": "stalwart",
    "algorithm": "Ed25519",
    "publicKey": "MCowBQYDK2VwAyEATESTPUBLICKEYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
    "privateKey": "-----BEGIN PRIVATE KEY-----MC4CAQAwBQYDK2VwBCIEITESTPRIVATEKEYSHOULDNEVERLEAKxxxxxxxxxx-----END PRIVATE KEY-----"
  },
  {
    "id": "dkim-2",
    "domain": "b.com",
    "selector": "stalwart",
    "algorithm": "Ed25519",
    "publicKey": "MCowBQYDK2VwAyEATESTPUBLICKEYBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=",
    "privateKey": "-----BEGIN PRIVATE KEY-----MC4CAQAwBQYDK2VwBCIEITESTPRIVATEKEYSHOULDNEVERLEAKyyyyyyyyyy-----END PRIVATE KEY-----"
  }
]
JSON
STUB
  chmod +x "$TMP/bin/stalwart-cli"

  run bash -c "cd '$TMP'; PATH='$TMP/bin':\$PATH $RUN_ENV bash scripts/dns-records.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TESTPUBLICKEYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"* ]]
  [[ "$output" == *"TESTPUBLICKEYBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"* ]]
  [[ "$output" != *"TESTPRIVATEKEYSHOULDNEVERLEAK"* ]]
  [[ "$output" != *"BEGIN PRIVATE KEY"* ]]
  [[ "$output" == *"stalwart._domainkey.a.com"* ]]
  [[ "$output" == *"stalwart._domainkey.b.com"* ]]
}

@test "swcli passes admin credentials via environment, not argv (avoids ps aux / cmdline exposure)" {
  # Stub captures both the argv it was called with and the STALWART_* env vars
  # it saw, so we can assert the password never appears on the command line.
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/stalwart-cli" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$ARGV_CAPTURE"
env | grep -E '^STALWART_(URL|USER|PASSWORD)=' | sort > "$ENV_CAPTURE"
echo '[]'
STUB
  chmod +x "$TMP/bin/stalwart-cli"

  run bash -c "cd '$TMP'; PATH='$TMP/bin':\$PATH ARGV_CAPTURE='$TMP/argv.txt' ENV_CAPTURE='$TMP/env.txt' $RUN_ENV bash scripts/dns-records.sh"
  [ "$status" -eq 0 ]

  argv="$(cat "$TMP/argv.txt")"
  [[ "$argv" != *"--password"* ]]
  [[ "$argv" != *"adminpass"* ]]

  envcap="$(cat "$TMP/env.txt")"
  [[ "$envcap" == *"STALWART_USER=admin"* ]]
  [[ "$envcap" == *"STALWART_PASSWORD=adminpass"* ]]
  [[ "$envcap" == *"STALWART_URL="* ]]
}

@test "dkim: a record with domainId instead of domain is skipped with a named-field warning and prints no DKIM TXT line" {
  # Models the schema-mismatch failure mode called out in dns-records.sh:
  # the live field is actually "domainId", not "domain". This must produce
  # a warning naming the missing field and must NOT print a DNS line with
  # an empty/short key (e.g. a bare "p=").
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/stalwart-cli" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
[
  {
    "id": "dkim-bad",
    "domainId": "a.com",
    "selector": "stalwart",
    "algorithm": "Ed25519",
    "publicKey": "MCowBQYDK2VwAyEATESTPUBLICKEYCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=",
    "privateKey": "-----BEGIN PRIVATE KEY-----MC4CAQAwBQYDK2VwBCIEITESTPRIVATEKEYSHOULDNEVERLEAKzzzzzzzzzz-----END PRIVATE KEY-----"
  }
]
JSON
STUB
  chmod +x "$TMP/bin/stalwart-cli"

  run bash -c "cd '$TMP'; PATH='$TMP/bin':\$PATH $RUN_ENV bash scripts/dns-records.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PERINGATAN"* ]]
  [[ "$output" == *"domain"* ]]
  [[ "$output" != *"v=DKIM1"* ]]
  [[ "$output" != *"_domainkey"* ]]
  [[ "$output" != *"TESTPUBLICKEYCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"* ]]
  [[ "$output" != *"TESTPRIVATEKEYSHOULDNEVERLEAK"* ]]
}

@test "dkim: a malformed record is skipped with a warning while a well-formed record in the same payload still prints" {
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/stalwart-cli" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
[
  {
    "id": "dkim-bad",
    "domainId": "a.com",
    "selector": "stalwart",
    "algorithm": "Ed25519",
    "publicKey": "MCowBQYDK2VwAyEATESTPUBLICKEYCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=",
    "privateKey": "-----BEGIN PRIVATE KEY-----shouldneverleak1-----END PRIVATE KEY-----"
  },
  {
    "id": "dkim-good",
    "domain": "b.com",
    "selector": "stalwart",
    "algorithm": "Ed25519",
    "publicKey": "MCowBQYDK2VwAyEATESTPUBLICKEYDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD=",
    "privateKey": "-----BEGIN PRIVATE KEY-----shouldneverleak2-----END PRIVATE KEY-----"
  }
]
JSON
STUB
  chmod +x "$TMP/bin/stalwart-cli"

  run bash -c "cd '$TMP'; PATH='$TMP/bin':\$PATH $RUN_ENV bash scripts/dns-records.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PERINGATAN"* ]]
  [[ "$output" == *"stalwart._domainkey.b.com"* ]]
  [[ "$output" == *"TESTPUBLICKEYDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"* ]]
  [[ "$output" != *"TESTPUBLICKEYCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"* ]]
  [[ "$output" != *"shouldneverleak"* ]]
}
