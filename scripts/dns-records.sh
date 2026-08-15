#!/usr/bin/env bash
# Prints every DNS record that must exist, in copy-paste form.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/env.sh
load_env

SERVER_IP="${SERVER_IP:-$(curl -s --max-time 5 ifconfig.me || echo '<IP_SERVER>')}"

echo "=== Cloudflare: SEMUA record DNS-only (grey cloud) ==="
echo
printf 'A    %-28s %s\n' "mail" "$SERVER_IP"
echo
for d in "$MAIL_DOMAIN_1" "$MAIL_DOMAIN_2"; do
  echo "--- $d ---"
  printf 'MX   %-28s %s (prio 10)\n' "@" "$MAIL_HOSTNAME"
  printf 'TXT  %-28s "v=spf1 include:_spf.resend.com -all"\n' "@"
  printf 'TXT  %-28s "v=DMARC1; p=none; rua=mailto:dmarc@%s"\n' "_dmarc" "$d"
  echo
done

echo "=== DKIM Stalwart (untuk penandatanganan lokal) ==="
if command -v stalwart-cli >/dev/null && [ -n "${STALWART_ADMIN_PASS:-}" ]; then
  source scripts/lib/cli.sh
  swcli query DkimSignature --json
else
  echo "(jalankan di server: source scripts/lib/cli.sh && swcli query DkimSignature --json)"
fi

echo
echo "=== DKIM Resend ==="
echo "Ambil dari dashboard Resend → Domains → <domain> → DNS Records."
echo "Pasang persis seperti yang mereka tampilkan, lalu klik Verify."
