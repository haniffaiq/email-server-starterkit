#!/usr/bin/env bash
# Prepares the host (swap, directories, permissions) and starts Stalwart.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/output.sh
source scripts/lib/env.sh
load_env

# 1. Swap: 2 GB RAM alone is too tight once the spam filter runs.
if [ "$(awk '/SwapTotal/ {print int($2/1024)}' /proc/meminfo)" -lt 1800 ]; then
  echo "membuat swap 2 GB..."
  sudo fallocate -l 2G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
  ok "swap 2 GB aktif"
else
  ok "swap sudah cukup"
fi

# 2. Data directories must be owned by UID 2000 (the image's unprivileged user).
sudo mkdir -p /opt/mail/etc /opt/mail/data
sudo cp config/config.json /opt/mail/etc/config.json
sudo chown -R 2000:2000 /opt/mail
ok "direktori /opt/mail siap, dimiliki UID 2000"

# 3. Start.
docker compose up -d
sleep 10

if docker compose ps --status running | grep -q stalwart; then
  ok "container stalwart jalan"
else
  fail "container tidak jalan — cek: docker compose logs"
fi

if curl -sf -o /dev/null http://127.0.0.1:8080/; then
  ok "admin UI merespons di 127.0.0.1:8080"
else
  fail "admin UI tidak merespons di 127.0.0.1:8080"
fi

mem=$(docker stats --no-stream --format '{{.MemUsage}}' stalwart 2>/dev/null || echo '?')
ok "pemakaian memori container: $mem"

summary
