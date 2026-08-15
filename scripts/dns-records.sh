#!/usr/bin/env bash
# Prints every DNS record that must exist, in copy-paste form.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/env.sh
load_env

if [ -z "${SERVER_IP:-}" ]; then
  # curl can exit 0 with empty output (e.g. blocked outbound traffic); guard both cases.
  SERVER_IP="$(curl -s --max-time 5 ifconfig.me || true)"
fi
SERVER_IP="${SERVER_IP:-<IP_SERVER>}"

echo "=== Cloudflare: SEMUA record DNS-only (grey cloud) ==="
echo
printf 'A    %-28s %s\n' "mail" "$SERVER_IP"
echo
for d in "$MAIL_DOMAIN_1" "$MAIL_DOMAIN_2"; do
  echo "--- $d ---"
  printf 'MX   %-28s %s (prio 10)\n' "@" "$MAIL_HOSTNAME"
  printf 'TXT  %-28s "v=spf1 include:_spf.resend.com -all"\n' "@"
  # rua points at MAIL_ADMIN_EMAIL, a real mailbox — a dmarc@<domain> address
  # is never created by this repo's plan, so reports sent there would bounce
  # and "two weeks of clean reports" would never actually arrive.
  printf 'TXT  %-28s "v=DMARC1; p=none; rua=mailto:%s"\n' "_dmarc" "$MAIL_ADMIN_EMAIL"
  echo
done

echo "=== DKIM Stalwart (untuk penandatanganan lokal) ==="
# NOTE: `swcli query DkimSignature --json` returns the full DkimSignature
# object, which includes the DKIM PRIVATE KEY — never dump that raw output.
# Only the selector + public key belong in DNS/chat/screenshots.
if ! command -v stalwart-cli >/dev/null; then
  echo "(stalwart-cli tidak ditemukan — jalankan skrip ini di server setelah stalwart-cli terpasang)"
elif [ -z "${STALWART_ADMIN_PASS:-}" ]; then
  echo "(STALWART_ADMIN_PASS belum diisi di .env — lengkapi dulu lalu jalankan ulang)"
elif ! command -v jq >/dev/null; then
  echo "(jq tidak ditemukan — install jq lalu jalankan ulang skrip ini."
  echo " JANGAN tempel output mentah 'swcli query DkimSignature --json' ke mana pun, itu memuat private key DKIM.)"
else
  source scripts/lib/cli.sh
  DKIM_JSON="$(swcli query DkimSignature --json)"
  # Project one JSON record per line first, then inspect .domain/.publicKey
  # per record in shell rather than folding everything into one jq filter:
  # jq's `+` treats a missing/null field as an empty operand ("str" + null ==
  # "str"), so a schema mismatch (e.g. the live field is really "domainId",
  # not "domain" — see config/plan.json.tpl) would otherwise silently print a
  # plausible-looking but empty/short DNS line (e.g. "p=") instead of failing.
  dkim_seen=0
  while IFS= read -r dkim_rec; do
    dkim_seen=1
    dkim_domain="$(printf '%s' "$dkim_rec" | jq -r '.domain // empty')"
    dkim_pubkey="$(printf '%s' "$dkim_rec" | jq -r '.publicKey // empty')"
    dkim_selector="$(printf '%s' "$dkim_rec" | jq -r '.selector // empty')"
    if [ -z "$dkim_domain" ] || [ -z "$dkim_pubkey" ] || [ -z "$dkim_selector" ]; then
      dkim_missing=""
      [ -z "$dkim_domain" ] && dkim_missing="domain"
      [ -z "$dkim_selector" ] && dkim_missing="${dkim_missing:+$dkim_missing, }selector"
      [ -z "$dkim_pubkey" ] && dkim_missing="${dkim_missing:+$dkim_missing, }publicKey"
      echo "PERINGATAN: field $dkim_missing kosong pada hasil 'swcli query DkimSignature --json' — kemungkinan nama field skema live berbeda dari yang dipakai skrip ini; cocokkan dengan 'swcli describe DkimSignature --json' lalu perbaiki scripts/dns-records.sh. Baris DKIM ini DILEWATI, bukan dicetak setengah kosong." >&2
      continue
    fi
    printf 'TXT  %s._domainkey.%s  "v=DKIM1; k=ed25519; p=%s"\n' "$dkim_selector" "$dkim_domain" "$dkim_pubkey"
  done < <(printf '%s' "$DKIM_JSON" | jq -c '.[]?')
  if [ "$dkim_seen" -eq 0 ]; then
    echo "(belum ada DkimSignature — jalankan 'make plan' dulu)"
  fi
fi

echo
echo "=== DKIM Resend ==="
echo "Ambil dari dashboard Resend → Domains → <domain> → DNS Records."
echo "Pasang persis seperti yang mereka tampilkan, lalu klik Verify."
