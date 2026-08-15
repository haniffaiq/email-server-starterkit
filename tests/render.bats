#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$TMP/scripts/lib" "$TMP/config"
  cp "$REPO_ROOT"/scripts/lib/*.sh "$TMP/scripts/lib/"
  cp "$REPO_ROOT/scripts/render-plan.sh" "$TMP/scripts/"
  cp "$REPO_ROOT/config/plan.json.tpl" "$TMP/config/"
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

# --- Task 5: domains, accounts, dkim ---

@test "render substitutes both domains" {
  run bash -c "cd '$TMP'; bash scripts/render-plan.sh"
  [ "$status" -eq 0 ]
  grep -q '"a.com"' "$TMP/config/plan.json"
  grep -q '"b.com"' "$TMP/config/plan.json"
}

@test "render leaves no unsubstituted placeholders" {
  bash -c "cd '$TMP'; bash scripts/render-plan.sh"
  run grep -c '\${' "$TMP/config/plan.json"
  [ "$output" -eq 0 ]
}

@test "every rendered line is valid JSON (NDJSON format)" {
  bash -c "cd '$TMP'; bash scripts/render-plan.sh"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo "$line" | python3 -c 'import json,sys; json.load(sys.stdin)'
  done < "$TMP/config/plan.json"
}

@test "rendered plan is not world readable" {
  bash -c "cd '$TMP'; bash scripts/render-plan.sh"
  perms=$(stat -f '%Lp' "$TMP/config/plan.json" 2>/dev/null || stat -c '%a' "$TMP/config/plan.json")
  [ "$perms" = "600" ]
}

# --- Task 6: listeners + acme dns-01 via cloudflare ---

@test "rendered plan wires the cloudflare token into the dns server object" {
  bash -c "cd '$TMP'; bash scripts/render-plan.sh"
  grep -q 'cftoken' "$TMP/config/plan.json"
}

@test "rendered plan declares all four mail listeners" {
  bash -c "cd '$TMP'; bash scripts/render-plan.sh"
  for port in 25 465 587 993; do
    grep -q "\"port\":$port" "$TMP/config/plan.json"
  done
}

@test "http listener binds to loopback only" {
  bash -c "cd '$TMP'; bash scripts/render-plan.sh"
  grep -q '127.0.0.1' "$TMP/config/plan.json"
  ! grep -q '"bindAddress":"0.0.0.0","port":8080' "$TMP/config/plan.json"
}

# --- Task 8 addendum: resend relay block lives in this same template ---

@test "rendered plan wires the resend relay as the default outbound route" {
  bash -c "cd '$TMP'; bash scripts/render-plan.sh"
  grep -q '"host":"smtp.resend.com"' "$TMP/config/plan.json"
  grep -q '"port":465' "$TMP/config/plan.json"
  grep -q 're_key' "$TMP/config/plan.json"
  grep -q '#relay-resend' "$TMP/config/plan.json"
}

# --- Task 10: rate limit for the application account ---

@test "rendered plan rate-limits the application account to 200 messages per hour" {
  bash -c "cd '$TMP'; bash scripts/render-plan.sh"
  grep -q '"accountId":"#acc-app"' "$TMP/config/plan.json"
  grep -q '"messages":200' "$TMP/config/plan.json"
}

# --- Task 11: optional inbound webhook ---

@test "webhook block is omitted when WEBHOOK_URL is empty" {
  cp "$REPO_ROOT/config/plan.webhook.tpl" "$TMP/config/"
  bash -c "cd '$TMP'; bash scripts/render-plan.sh"
  run grep -c 'Webhook' "$TMP/config/plan.json"
  [ "$output" -eq 0 ]
}

@test "webhook block is included when WEBHOOK_URL is set" {
  cp "$REPO_ROOT/config/plan.webhook.tpl" "$TMP/config/"
  echo 'WEBHOOK_URL=https://app.example.com/hook' >> "$TMP/.env"
  bash -c "cd '$TMP'; bash scripts/render-plan.sh"
  grep -q 'https://app.example.com/hook' "$TMP/config/plan.json"
}

# --- Schema-reconciliation comment block must never leak into the rendered plan ---

@test "template carries a reconcile-with-swcli-describe comment block" {
  grep -q '^#' "$TMP/config/plan.json.tpl"
}

@test "comment lines in the template are stripped from the rendered plan" {
  bash -c "cd '$TMP'; bash scripts/render-plan.sh"
  run grep -c '^#' "$TMP/config/plan.json"
  [ "$output" -eq 0 ]
}
