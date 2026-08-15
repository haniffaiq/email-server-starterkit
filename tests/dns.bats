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
CF_API_TOKEN=cftoken
RESEND_API_KEY=re_key
ADMIN_ALLOW_IP=1.2.3.4
STALWART_ADMIN_PASS=adminpass
EOF
}

@test "prints an MX record for each domain" {
  run bash -c "cd '$TMP'; bash scripts/dns-records.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"MX"*"a.com"* ]]
  [[ "$output" == *"MX"*"b.com"* ]]
}

@test "spf points at resend, not at the server itself" {
  run bash -c "cd '$TMP'; bash scripts/dns-records.sh"
  [[ "$output" == *"include:_spf.resend.com"* ]]
  [[ "$output" != *"v=spf1 mx"* ]]
}

@test "prints a dmarc record starting at p=none" {
  run bash -c "cd '$TMP'; bash scripts/dns-records.sh"
  [[ "$output" == *"v=DMARC1"* ]]
  [[ "$output" == *"p=none"* ]]
}

@test "never prints the cloudflare token or resend key" {
  run bash -c "cd '$TMP'; bash scripts/dns-records.sh"
  [[ "$output" != *"cftoken"* ]]
  [[ "$output" != *"re_key"* ]]
}
