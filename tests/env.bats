#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$TMP/scripts/lib"
  cp "$REPO_ROOT/scripts/lib/env.sh" "$TMP/scripts/lib/"
}

@test "load_env fails when .env is missing" {
  run bash -c "cd '$TMP'; source scripts/lib/env.sh; load_env"
  [ "$status" -eq 1 ]
  [[ "$output" == *".env"* ]]
}

@test "load_env fails when a required variable is empty" {
  printf 'MAIL_HOSTNAME=mail.a.com\nMAIL_DOMAIN_1=\n' > "$TMP/.env"
  run bash -c "cd '$TMP'; source scripts/lib/env.sh; load_env"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MAIL_DOMAIN_1"* ]]
}

@test "load_env exports variables when all required ones are set" {
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
  run bash -c "cd '$TMP'; source scripts/lib/env.sh; load_env; echo \"got=\$MAIL_DOMAIN_2\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"got=b.com"* ]]
}

@test "load_env tolerates comments and blank lines" {
  cat > "$TMP/.env" <<'EOF'
# komentar
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
  run bash -c "cd '$TMP'; source scripts/lib/env.sh; load_env; echo \"host=\$MAIL_HOSTNAME\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"host=mail.a.com"* ]]
}

@test "load_env fails when MAIL_USER_2 is empty (second domain must have its own mailbox)" {
  cat > "$TMP/.env" <<'EOF'
MAIL_HOSTNAME=mail.a.com
MAIL_DOMAIN_1=a.com
MAIL_DOMAIN_2=b.com
MAIL_ADMIN_EMAIL=admin@a.com
MAIL_USER_1=hanif@a.com
MAIL_USER_1_PASS=secret1
MAIL_APP_USER=noreply@a.com
MAIL_APP_PASS=secret2
MAIL_USER_2=
MAIL_USER_2_PASS=secret3
CF_API_TOKEN=cftoken
RESEND_API_KEY=re_key
ADMIN_ALLOW_IP=1.2.3.4
STALWART_ADMIN_PASS=adminpass
EOF
  run bash -c "cd '$TMP'; source scripts/lib/env.sh; load_env"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MAIL_USER_2"* ]]
}
