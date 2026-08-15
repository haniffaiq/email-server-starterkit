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
MAIL_USER_2=second@b.com
MAIL_USER_2_PASS=secret3
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

@test "http listener binds to 0.0.0.0 inside the container (host exposure is controlled by docker-compose, not this bind)" {
  bash -c "cd '$TMP'; bash scripts/render-plan.sh"
  grep -q '"bindAddress":"0.0.0.0","port":8080' "$TMP/config/plan.json"
}

@test "docker-compose (not this repo's plan) is what actually restricts the admin port to loopback" {
  # The plan template binds 0.0.0.0 inside the container netns (see above); the
  # real protection is docker-compose.yml publishing the port as 127.0.0.1-only.
  grep -q '"127.0.0.1:8080:8080"' "$REPO_ROOT/docker-compose.yml"
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

# --- Critical 1: secrets must be JSON-escaped, not inserted raw ---

@test "secrets containing double quotes, backslashes, and dollar signs survive the JSON round-trip unchanged" {
  # .env is sourced as a bash script (see load_env), so values with shell
  # metacharacters must be single-quoted here just like a real operator would.
  cat >> "$TMP/.env" <<'EOF'
MAIL_USER_1_PASS='w"eird$pass'
MAIL_APP_PASS='back\slash\tword'
EOF
  run bash -c "cd '$TMP'; bash scripts/render-plan.sh"
  [ "$status" -eq 0 ]
  python3 - "$TMP/config/plan.json" <<'PY'
import json, sys
found1 = found2 = False
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    obj = json.loads(line)
    if obj.get("object") == "Account":
        accs = obj["value"]
        if accs.get("acc-user", {}).get("secrets") == ['w"eird$pass']:
            found1 = True
        if accs.get("acc-app", {}).get("secrets") == ['back\\slash\\tword']:
            found2 = True
assert found1, "acc-user secret did not round-trip"
assert found2, "acc-app secret did not round-trip"
PY
}

@test "render aborts with an Indonesian message naming the bad line when a rendered line is not valid JSON" {
  cat > "$TMP/config/plan.json.tpl" <<'EOF'
# comment, stripped before validation
{"@type":"upsert","object":"Domain","matchOn":["name"],"value":{"dom-1":{"name":"${MAIL_DOMAIN_1}"}}}
{this is not valid json}
EOF
  run bash -c "cd '$TMP'; bash scripts/render-plan.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"baris 2"* ]]
  [[ "$output" == *"JSON"* ]]
}

# --- Important 3: SystemSettings must be a single merged update ---

@test "SystemSettings default domain and default relay host are merged into a single update" {
  bash -c "cd '$TMP'; bash scripts/render-plan.sh"
  run grep -c '"object":"SystemSettings"' "$TMP/config/plan.json"
  [ "$output" -eq 1 ]
  grep -q '"defaultDomainId":"#dom-1"' "$TMP/config/plan.json"
  grep -q '"defaultRelayHostId":"#relay-resend"' "$TMP/config/plan.json"
}

@test "merged SystemSettings update appears after both dom-1 and relay-resend are defined" {
  bash -c "cd '$TMP'; bash scripts/render-plan.sh"
  domain_line=$(grep -n '"dom-1"' "$TMP/config/plan.json" | head -1 | cut -d: -f1)
  relay_line=$(grep -n '"object":"RelayHost"' "$TMP/config/plan.json" | head -1 | cut -d: -f1)
  settings_line=$(grep -n '"object":"SystemSettings"' "$TMP/config/plan.json" | head -1 | cut -d: -f1)
  [ "$settings_line" -gt "$domain_line" ]
  [ "$settings_line" -gt "$relay_line" ]
}

# --- Important 4: second domain gets its own mailbox ---

@test "second domain (b.com) gets its own mailbox account, not just accounts on a.com" {
  bash -c "cd '$TMP'; bash scripts/render-plan.sh"
  grep -q '"second@b.com"' "$TMP/config/plan.json"
  python3 - "$TMP/config/plan.json" <<'PY'
import json, sys
found = False
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    obj = json.loads(line)
    if obj.get("object") == "Account":
        for acc in obj["value"].values():
            if acc.get("emails") == ["second@b.com"] and acc.get("secrets") == ["secret3"]:
                found = True
assert found, "no Account entry for the second domain's mailbox"
PY
}

# --- Minor 8: operation-count message must not carry BSD wc's leading whitespace ---

@test "operation count in the success message has no stray leading whitespace" {
  run bash -c "cd '$TMP'; bash scripts/render-plan.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *"( "* ]]
  [[ "$output" =~ \([0-9]+\ operasi\) ]]
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
