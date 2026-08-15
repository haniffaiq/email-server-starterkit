#!/usr/bin/env bash
# Verifies the host can actually run a mail server before anything is installed.
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/output.sh

echo "== Preflight mail server =="

# 1. Inbound port 25 must be free so Stalwart can bind it.
if ss -tlnp 2>/dev/null | grep -q ':25 '; then
  fail "port 25 sudah dipakai proses lain (cek: sudo ss -tlnp | grep ':25 ')"
else
  ok "port 25 bebas dipakai"
fi

# 2. Ports the reverse proxy already owns must stay untouched by us.
for p in 465 587 993; do
  if ss -tlnp 2>/dev/null | grep -q ":$p "; then
    fail "port $p sudah dipakai proses lain"
  else
    ok "port $p bebas dipakai"
  fi
done

# 3. Outbound 25 is expected to be BLOCKED on this provider; relay handles sending.
if timeout 8 bash -c 'cat < /dev/tcp/gmail-smtp-in.l.google.com/25' >/dev/null 2>&1; then
  warn "port 25 keluar ternyata TERBUKA — relay tetap dipakai sesuai spec, tapi pengiriman langsung juga mungkin"
else
  ok "port 25 keluar diblokir (sesuai dugaan) — outbound lewat relay Resend"
fi

# 4. Memory and swap.
mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
swap_mb=$(awk '/SwapTotal/ {print int($2/1024)}' /proc/meminfo)
[ "$mem_mb" -ge 1800 ] && ok "RAM ${mem_mb} MB" || fail "RAM cuma ${mem_mb} MB, terlalu kecil"
[ "$swap_mb" -ge 1800 ] && ok "swap ${swap_mb} MB" || warn "swap ${swap_mb} MB — bootstrap.sh akan bikin 2 GB"

# 5. Docker.
command -v docker >/dev/null && ok "docker terpasang" || fail "docker belum terpasang"
docker compose version >/dev/null 2>&1 && ok "docker compose plugin ada" || fail "docker compose plugin belum ada"

# 6. Disk.
free_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
[ "$free_gb" -ge 10 ] && ok "disk kosong ${free_gb} GB" || fail "disk kosong cuma ${free_gb} GB"

summary
