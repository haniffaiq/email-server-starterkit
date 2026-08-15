#!/usr/bin/env bash
# Renders the declarative plan template with values from .env.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/env.sh
load_env

# Only substitute the variables we own, so any literal $ in the template survives.
# MAIL_HOSTNAME is deliberately NOT in this list: the template never uses it.
VARS='${MAIL_DOMAIN_1} ${MAIL_DOMAIN_2} ${MAIL_ADMIN_EMAIL} ${MAIL_USER_1} ${MAIL_USER_1_PASS} ${MAIL_APP_USER} ${MAIL_APP_PASS} ${MAIL_USER_2} ${MAIL_USER_2_PASS} ${CF_API_TOKEN} ${RESEND_API_KEY}'

# envsubst inserts values raw. A value containing `"` would produce invalid
# NDJSON (loud failure); a value containing `\` would produce valid-but-wrong
# JSON (e.g. `\t` becomes a tab), silently storing a different secret than the
# one in .env. JSON-escape every substituted value before it reaches envsubst.
# We overwrite each variable in this script's own environment with its
# escaped form; nothing downstream in this process needs the raw value again,
# and other scripts/processes source .env fresh so they are unaffected.
json_escape() {
  python3 -c 'import json, sys; s = json.dumps(sys.argv[1]); print(s[1:-1])' "$1"
}

for var in MAIL_DOMAIN_1 MAIL_DOMAIN_2 MAIL_ADMIN_EMAIL \
           MAIL_USER_1 MAIL_USER_1_PASS MAIL_APP_USER MAIL_APP_PASS \
           MAIL_USER_2 MAIL_USER_2_PASS CF_API_TOKEN RESEND_API_KEY; do
  export "$var=$(json_escape "${!var}")"
done

umask 077

# Strip comment lines (see the reconcile-with-swcli-describe notice at the top
# of config/plan.json.tpl) and blank formatting lines before substitution, so
# the rendered file is pure NDJSON — one JSON operation per line.
grep -vE '^[[:space:]]*(#|$)' config/plan.json.tpl | envsubst "$VARS" > config/plan.json

# The webhook path is opt-in: only rendered when the app endpoint is configured.
if [ -n "${WEBHOOK_URL:-}" ] && [ -f config/plan.webhook.tpl ]; then
  export WEBHOOK_URL="$(json_escape "$WEBHOOK_URL")"
  grep -vE '^[[:space:]]*(#|$)' config/plan.webhook.tpl | envsubst '${WEBHOOK_URL}' >> config/plan.json
fi

chmod 600 config/plan.json

if grep -q '\${' config/plan.json; then
  echo "masih ada placeholder yang belum tergantikan di config/plan.json" >&2
  exit 1
fi

# Belt-and-suspenders on top of the escaping above: every non-empty rendered
# line must parse as JSON on its own (NDJSON, one operation per line). If it
# doesn't, name the exact line number so the operator doesn't have to guess.
line_no=0
while IFS= read -r line || [ -n "$line" ]; do
  line_no=$((line_no + 1))
  [ -n "$line" ] || continue
  if ! printf '%s' "$line" | python3 -c 'import json, sys; json.load(sys.stdin)' >/dev/null 2>&1; then
    echo "baris $line_no di config/plan.json bukan JSON yang valid" >&2
    exit 1
  fi
done < config/plan.json

line_count="$(wc -l < config/plan.json | tr -d '[:space:]')"
echo "config/plan.json siap ($line_count operasi)"
