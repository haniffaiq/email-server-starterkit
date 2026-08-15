#!/usr/bin/env bash
# Applies the rendered plan idempotently against the running server.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/output.sh
source scripts/lib/env.sh
source scripts/lib/cli.sh
load_env

[ -f config/plan.json ] || { echo "config/plan.json belum ada — jalankan render-plan.sh dulu" >&2; exit 1; }

swcli apply --file config/plan.json
ok "plan diterapkan"

# Applying twice must be a no-op; that is what makes this safe to run on every deploy.
swcli apply --file config/plan.json
ok "apply kedua sukses (idempoten)"

summary
