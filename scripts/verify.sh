#!/usr/bin/env bash
# End-to-end health check: can this server send, receive, and stay closed to abuse?
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/output.sh
source scripts/lib/env.sh
load_env

echo "== Verifikasi mail server =="

# 1. Container alive.
docker compose ps --status running | grep -q stalwart \
  && ok "container jalan" || fail "container mati"

# 2. Inbound port 25 listening.
ss -tlnp 2>/dev/null | grep -q ':25 ' \
  && ok "port 25 didengarkan" || fail "tidak ada yang dengar di port 25"

# 3. Certificate valid on the submission port.
cert=$(openssl s_client -connect "${MAIL_HOSTNAME}:465" -servername "${MAIL_HOSTNAME}" \
        </dev/null 2>/dev/null | openssl x509 -noout -subject -dates 2>/dev/null)
if echo "$cert" | grep -q "$MAIL_HOSTNAME"; then
  ok "sertifikat TLS cocok dengan $MAIL_HOSTNAME"
else
  fail "sertifikat TLS tidak cocok atau tidak ada"
fi

# 4. IMAP login works.
imap=$(openssl s_client -connect "${MAIL_HOSTNAME}:993" -quiet 2>/dev/null <<EOF
a LOGIN ${MAIL_USER_1} ${MAIL_USER_1_PASS}
a LOGOUT
EOF
)
echo "$imap" | grep -q '^a OK' \
  && ok "login IMAP berhasil" || fail "login IMAP gagal"

# 5. Open relay test: relaying to a foreign domain without auth must be refused.
relay=$(printf 'EHLO test\r\nMAIL FROM:<probe@example.org>\r\nRCPT TO:<probe@gmail.com>\r\nQUIT\r\n' \
        | timeout 15 nc 127.0.0.1 25 2>/dev/null)
if echo "$relay" | grep -qE '^250 .*(Recipient|Accepted)'; then
  fail "OPEN RELAY — server menerima relay tanpa auth, MATIKAN port 25 sekarang dan perbaiki"
else
  ok "open-relay test negatif (relay tanpa auth ditolak)"
fi

# 6. DNS records present.
for d in "$MAIL_DOMAIN_1" "$MAIL_DOMAIN_2"; do
  dig +short MX "$d" | grep -q "$MAIL_HOSTNAME" \
    && ok "MX $d benar" || fail "MX $d belum menunjuk $MAIL_HOSTNAME"
  dig +short TXT "$d" | grep -q 'v=spf1' \
    && ok "SPF $d ada" || fail "SPF $d belum ada"
  dig +short TXT "_dmarc.$d" | grep -q 'v=DMARC1' \
    && ok "DMARC $d ada" || fail "DMARC $d belum ada"
done

# 7. Memory headroom.
mem=$(docker stats --no-stream --format '{{.MemPerc}}' stalwart 2>/dev/null | tr -d '%' | cut -d. -f1)
if [ -n "$mem" ] && [ "$mem" -lt 85 ]; then
  ok "memori container ${mem}% dari limit"
else
  warn "memori container ${mem}% dari limit — pertimbangkan naikkan mem_limit"
fi

summary
