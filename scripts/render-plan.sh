#!/usr/bin/env bash
# Renders the declarative plan template with values from .env.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/env.sh
load_env

# Only substitute the variables we own, so any literal $ in the template survives.
VARS='${MAIL_HOSTNAME} ${MAIL_DOMAIN_1} ${MAIL_DOMAIN_2} ${MAIL_ADMIN_EMAIL} ${MAIL_USER_1} ${MAIL_USER_1_PASS} ${MAIL_APP_USER} ${MAIL_APP_PASS} ${CF_API_TOKEN} ${RESEND_API_KEY}'

umask 077

# Strip comment lines (see the reconcile-with-swcli-describe notice at the top
# of config/plan.json.tpl) and blank formatting lines before substitution, so
# the rendered file is pure NDJSON — one JSON operation per line.
grep -vE '^[[:space:]]*(#|$)' config/plan.json.tpl | envsubst "$VARS" > config/plan.json

# The webhook path is opt-in: only rendered when the app endpoint is configured.
if [ -n "${WEBHOOK_URL:-}" ] && [ -f config/plan.webhook.tpl ]; then
  grep -vE '^[[:space:]]*(#|$)' config/plan.webhook.tpl | envsubst '${WEBHOOK_URL}' >> config/plan.json
fi

chmod 600 config/plan.json

if grep -q '\${' config/plan.json; then
  echo "masih ada placeholder yang belum tergantikan di config/plan.json" >&2
  exit 1
fi
echo "config/plan.json siap ($(wc -l < config/plan.json) operasi)"
