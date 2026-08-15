# Email Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Repo yang bisa langsung menjalankan mail server sendiri (terima + kirim) untuk 2 domain di VPS Tencent Lighthouse 2 GB, dengan konfigurasi deklaratif yang di-commit sebagai kode.

**Architecture:** Satu container Stalwart v0.16 (SMTP + IMAP + spam filter + admin UI) dengan RocksDB embedded di bind mount `/opt/mail`. Konfigurasi operasional tidak ditulis tangan di server: ada plan NDJSON deklaratif di repo yang di-render dari `.env` lalu diterapkan idempoten dengan `stalwart-cli apply`. Inbound diterima langsung di port 25; outbound dikirim lewat relay Resend karena port 25 keluar diblokir provider. TLS untuk port mail diurus Stalwart sendiri lewat ACME DNS-01 ke Cloudflare, sementara admin UI di-proxy nginx yang sudah ada.

**Tech Stack:** Docker Compose, Stalwart Mail Server v0.16 (`stalwartlabs/stalwart:v0.16`), `stalwart-cli`, RocksDB, Cloudflare DNS, Resend SMTP relay, nginx, bash + `envsubst`, bats-core untuk uji skrip.

**Spec:** `docs/superpowers/specs/2026-08-15-email-server-design.md`

## Global Constraints

- Image dipin ke `stalwartlabs/stalwart:v0.16` — jangan pernah `latest`.
- Bind mount host `/opt/mail` harus dimiliki UID 2000 (`chown -R 2000:2000 /opt/mail`), syarat image Stalwart.
- Container dibatasi `mem_limit: 1200m`; host wajib punya swap 2 GB.
- Config di disk hanya `config/config.json` berisi objek DataStore. Semua setting lain lewat plan deklaratif.
- Plan file berformat **NDJSON**: satu operasi JSON per baris, tanpa array pembungkus.
- Referensi antar-objek dalam plan memakai sintaks `#<client-id>` (contoh `"domainId":"#dom-a"`).
- Nama akun harus alamat email lengkap (`hanif@domain.com`), bukan username telanjang.
- Tidak ada rahasia yang di-commit: `.env`, `config/plan.json` (hasil render), dan `/opt/mail` masuk `.gitignore`. Yang di-commit hanya `.env.example` dan `config/plan.json.tpl`.
- Cloudflare API token dibatasi izin `Zone:DNS:Edit` untuk zona yang dipakai saja.
- HTTP admin Stalwart hanya bind ke `127.0.0.1:8080`, tidak pernah ke `0.0.0.0`.
- Semua record DNS di Cloudflare harus DNS-only (grey cloud).
- README dan pesan skrip ditulis dalam bahasa Indonesia; komentar kode dan pesan commit dalam bahasa Inggris.
- Variabel `.env` yang dipakai lintas task, nama persis: `MAIL_HOSTNAME`, `MAIL_DOMAIN_1`, `MAIL_DOMAIN_2`, `MAIL_ADMIN_EMAIL`, `MAIL_USER_1`, `MAIL_USER_1_PASS`, `MAIL_APP_USER`, `MAIL_APP_PASS`, `CF_API_TOKEN`, `RESEND_API_KEY`, `ADMIN_ALLOW_IP`, `STALWART_ADMIN_PASS`.

---

### Task 1: Preflight konektivitas — gerbang go/no-go

Task ini menentukan apakah sisa plan layak dikerjakan. Kalau port 25 inbound tertutup, penerimaan email tidak bisa di-self-host dan arsitekturnya harus dirombak. Kerjakan ini sampai tuntas sebelum menyentuh task lain.

**Files:**
- Create: `scripts/preflight.sh`
- Create: `scripts/lib/output.sh`
- Test: `tests/preflight.bats`

**Interfaces:**
- Consumes: tidak ada
- Produces: `scripts/lib/output.sh` mengekspor fungsi `ok "<pesan>"`, `fail "<pesan>"`, `warn "<pesan>"`, dan `summary` yang dipakai semua skrip berikutnya. `ok`/`warn` mencetak ke stdout dan mengembalikan 0; `fail` mencetak ke stdout, menaikkan counter `FAIL_COUNT`, dan mengembalikan 0 supaya skrip melanjutkan pemeriksaan lain; `summary` mencetak total dan `exit 1` bila `FAIL_COUNT > 0`.

- [ ] **Step 1: Tulis test yang gagal**

Buat `tests/preflight.bats`:

```bash
#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  source "$REPO_ROOT/scripts/lib/output.sh"
}

@test "ok() prints a pass marker and keeps FAIL_COUNT at zero" {
  run bash -c "source '$REPO_ROOT/scripts/lib/output.sh'; ok 'port terbuka'; echo \"count=\$FAIL_COUNT\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"port terbuka"* ]]
  [[ "$output" == *"count=0"* ]]
}

@test "fail() increments FAIL_COUNT but does not abort the script" {
  run bash -c "source '$REPO_ROOT/scripts/lib/output.sh'; fail 'port tertutup'; echo 'masih jalan'; echo \"count=\$FAIL_COUNT\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"masih jalan"* ]]
  [[ "$output" == *"count=1"* ]]
}

@test "summary() exits non-zero when there was a failure" {
  run bash -c "source '$REPO_ROOT/scripts/lib/output.sh'; fail 'x'; summary"
  [ "$status" -eq 1 ]
}

@test "summary() exits zero when everything passed" {
  run bash -c "source '$REPO_ROOT/scripts/lib/output.sh'; ok 'x'; summary"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Jalankan test, pastikan gagal**

Run: `bats tests/preflight.bats`
Expected: FAIL — `scripts/lib/output.sh: No such file or directory`

(Kalau `bats` belum ada: `brew install bats-core` di macOS, `apt-get install -y bats` di server.)

- [ ] **Step 3: Tulis `scripts/lib/output.sh`**

```bash
#!/usr/bin/env bash
# Shared pass/fail reporting used by every script in this repo.

FAIL_COUNT=${FAIL_COUNT:-0}
PASS_COUNT=${PASS_COUNT:-0}

ok()   { printf '  \033[32mOK\033[0m    %s\n' "$1"; PASS_COUNT=$((PASS_COUNT + 1)); return 0; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; return 0; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL_COUNT=$((FAIL_COUNT + 1)); return 0; }

summary() {
  printf '\n%s lulus, %s gagal\n' "$PASS_COUNT" "$FAIL_COUNT"
  [ "$FAIL_COUNT" -eq 0 ] || exit 1
}
```

- [ ] **Step 4: Jalankan test, pastikan lulus**

Run: `bats tests/preflight.bats`
Expected: 4 tests, 0 failures

- [ ] **Step 5: Tulis `scripts/preflight.sh`**

```bash
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
```

- [ ] **Step 6: Jalankan preflight di server, catat hasilnya**

Run di server: `bash scripts/preflight.sh`
Expected: setiap baris tercetak dengan penanda OK/WARN/FAIL, exit code 0 kalau tidak ada FAIL.

- [ ] **Step 7: Buktikan port 25 inbound dijangkau dari internet — GERBANG**

Di server: `sudo nc -l 25`
Dari laptop: `nc -vz -w 5 <IP_SERVER> 25`

Expected: laptop mencetak `succeeded!` / `Connected`.

Kalau gagal: buka dulu port 25 di security group Tencent lalu ulangi. Kalau tetap gagal setelah security group terbuka, **berhenti di sini** dan laporkan ke user — inbound diblokir provider dan arsitektur spec tidak berlaku.

- [ ] **Step 8: Commit**

```bash
git add scripts/lib/output.sh scripts/preflight.sh tests/preflight.bats
git commit -m "feat: add preflight connectivity and resource checks"
```

---

### Task 2: Kerangka repo, env, dan Makefile

**Files:**
- Create: `.env.example`
- Create: `.gitignore`
- Create: `Makefile`
- Create: `scripts/lib/env.sh`
- Test: `tests/env.bats`

**Interfaces:**
- Consumes: `scripts/lib/output.sh` dari Task 1
- Produces: `scripts/lib/env.sh` mengekspor `load_env` — memuat `.env` dari root repo ke environment lalu memastikan setiap variabel wajib terisi; keluar dengan status 1 dan pesan `variabel <NAMA> belum diisi di .env` bila ada yang kosong.

- [ ] **Step 1: Tulis test yang gagal**

Buat `tests/env.bats`:

```bash
#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$TMP/scripts/lib"
  cp "$REPO_ROOT/scripts/lib/output.sh" "$TMP/scripts/lib/"
  cp "$REPO_ROOT/scripts/lib/env.sh" "$TMP/scripts/lib/"
}

@test "load_env fails when .env is missing" {
  run bash -c "cd '$TMP'; source scripts/lib/env.sh; load_env"
  [ "$status" -eq 1 ]
  [[ "$output" == *".env"* ]]
}

@test "load_env fails when a required variable is empty" {
  printf 'MAIL_HOSTNAME=mail.a.com\nMAIL_DOMAIN_1=\n' > "$TMP/.env"
  run bash -c "cd '$TMP'; source scripts/lib/env.sh; load_env"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MAIL_DOMAIN_1"* ]]
}

@test "load_env exports variables when all required ones are set" {
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
  run bash -c "cd '$TMP'; source scripts/lib/env.sh; load_env; echo \"got=\$MAIL_DOMAIN_2\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"got=b.com"* ]]
}

@test "load_env tolerates comments and blank lines" {
  cat > "$TMP/.env" <<'EOF'
# komentar
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
  run bash -c "cd '$TMP'; source scripts/lib/env.sh; load_env; echo \"host=\$MAIL_HOSTNAME\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"host=mail.a.com"* ]]
}
```

- [ ] **Step 2: Jalankan test, pastikan gagal**

Run: `bats tests/env.bats`
Expected: FAIL — `scripts/lib/env.sh` belum ada.

- [ ] **Step 3: Tulis `scripts/lib/env.sh`**

```bash
#!/usr/bin/env bash
# Loads and validates .env for every script in this repo.

REQUIRED_VARS=(
  MAIL_HOSTNAME MAIL_DOMAIN_1 MAIL_DOMAIN_2 MAIL_ADMIN_EMAIL
  MAIL_USER_1 MAIL_USER_1_PASS MAIL_APP_USER MAIL_APP_PASS
  CF_API_TOKEN RESEND_API_KEY ADMIN_ALLOW_IP STALWART_ADMIN_PASS
)

load_env() {
  local env_file="${1:-.env}"
  if [ ! -f "$env_file" ]; then
    echo "file $env_file tidak ada — salin dari .env.example dulu" >&2
    return 1
  fi
  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
  local missing=0
  for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
      echo "variabel $var belum diisi di $env_file" >&2
      missing=1
    fi
  done
  return "$missing"
}
```

- [ ] **Step 4: Jalankan test, pastikan lulus**

Run: `bats tests/env.bats`
Expected: 4 tests, 0 failures

- [ ] **Step 5: Tulis `.env.example`**

```bash
# Hostname mail server. Harus punya A record ke IP server ini.
MAIL_HOSTNAME=mail.domain-utama.com

# Dua domain yang dilayani.
MAIL_DOMAIN_1=domain-utama.com
MAIL_DOMAIN_2=domain-kedua.com

# Kontak admin: dipakai Let's Encrypt untuk notifikasi kedaluwarsa sertifikat.
MAIL_ADMIN_EMAIL=hanif@domain-utama.com

# Mailbox pribadi. Nama akun WAJIB alamat email lengkap.
MAIL_USER_1=hanif@domain-utama.com
MAIL_USER_1_PASS=ganti-password-kuat-ini

# Akun terpisah untuk aplikasi. Rate limit-nya sendiri, tidak bisa baca mailbox pribadi.
MAIL_APP_USER=noreply@domain-utama.com
MAIL_APP_PASS=ganti-password-kuat-ini-juga

# Cloudflare API token, izin Zone:DNS:Edit untuk kedua zona saja. Dipakai ACME DNS-01.
CF_API_TOKEN=

# API key Resend, dipakai sebagai password SMTP relay (username-nya "resend").
RESEND_API_KEY=

# IP yang boleh membuka admin UI lewat nginx. Pisahkan dengan spasi untuk banyak IP.
ADMIN_ALLOW_IP=1.2.3.4

# Password admin Stalwart. Diisi saat bootstrap.
STALWART_ADMIN_PASS=
```

- [ ] **Step 6: Tulis `.gitignore`**

```
.env
config/plan.json
data/
*.pem
```

- [ ] **Step 7: Tulis `Makefile`**

```makefile
.DEFAULT_GOAL := help

help: ## Tampilkan daftar perintah
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

preflight: ## Cek server siap atau belum
	bash scripts/preflight.sh

up: ## Jalankan Stalwart
	bash scripts/bootstrap.sh

plan: ## Render dan terapkan konfigurasi deklaratif
	bash scripts/render-plan.sh && bash scripts/apply-plan.sh

dns: ## Cetak record DNS yang harus dipasang
	bash scripts/dns-records.sh

verify: ## Uji kirim, terima, dan autentikasi email
	bash scripts/verify.sh

logs: ## Ikuti log container
	docker compose logs -f --tail=100

test: ## Jalankan unit test skrip
	bats tests/

.PHONY: help preflight up plan dns verify logs test
```

- [ ] **Step 8: Verifikasi Makefile jalan**

Run: `make help` lalu `make test`
Expected: `make help` mencetak 7 target; `make test` menjalankan seluruh bats dan lulus.

- [ ] **Step 9: Commit**

```bash
git add .env.example .gitignore Makefile scripts/lib/env.sh tests/env.bats
git commit -m "feat: add env loading, example config, and make targets"
```

---

### Task 3: Container Stalwart hidup dengan bind mount dan batas memori

**Files:**
- Create: `docker-compose.yml`
- Create: `config/config.json`
- Create: `scripts/bootstrap.sh`
- Modify: `.env` (isi `STALWART_ADMIN_PASS` hasil generate)

**Interfaces:**
- Consumes: `load_env` dari Task 2, `ok/fail/summary` dari Task 1
- Produces: container bernama `stalwart` berjalan; datastore di `/opt/mail/data`; HTTP admin dengar di `127.0.0.1:8080`; kredensial admin `admin` / `$STALWART_ADMIN_PASS`.

- [ ] **Step 1: Tulis `config/config.json`**

Ini satu-satunya konfigurasi yang tinggal di disk. Isinya hanya lokasi datastore.

```json
{"@type":"RocksDb","path":"/var/lib/stalwart"}
```

- [ ] **Step 2: Tulis `docker-compose.yml`**

```yaml
services:
  stalwart:
    image: stalwartlabs/stalwart:v0.16
    container_name: stalwart
    restart: always
    # Public mail ports. HTTP admin is bound to loopback only and reached via nginx.
    ports:
      - "25:25"
      - "465:465"
      - "587:587"
      - "993:993"
      - "127.0.0.1:8080:8080"
    volumes:
      - /opt/mail/etc:/etc/stalwart
      - /opt/mail/data:/var/lib/stalwart
    environment:
      # Fixed admin credentials so bootstrap is reproducible instead of scraping logs.
      STALWART_RECOVERY_ADMIN: "admin:${STALWART_ADMIN_PASS}"
      STALWART_PUBLIC_URL: "https://${MAIL_HOSTNAME}"
    mem_limit: 1200m
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
```

- [ ] **Step 3: Tulis `scripts/bootstrap.sh`**

```bash
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
```

- [ ] **Step 4: Isi password admin di `.env`**

```bash
printf 'STALWART_ADMIN_PASS=%s\n' "$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)" >> .env
```

Lalu hapus baris `STALWART_ADMIN_PASS=` yang kosong dari `.env` supaya tidak menimpa nilai baru (yang terbaca terakhir yang menang, jadi urutannya harus benar).

- [ ] **Step 5: Jalankan bootstrap**

Run di server: `make up`
Expected: semua baris OK, exit 0, container `stalwart` berstatus running, memori terpakai di bawah 600 MB.

- [ ] **Step 6: Verifikasi HTTP admin tidak terekspos ke internet**

Run dari laptop: `nc -vz -w 5 <IP_SERVER> 8080`
Expected: gagal / connection refused. Kalau berhasil, port binding salah — perbaiki `docker-compose.yml` sebelum lanjut.

- [ ] **Step 7: Commit**

```bash
git add docker-compose.yml config/config.json scripts/bootstrap.sh
git commit -m "feat: run stalwart container with swap, bind mounts, and memory cap"
```

---

### Task 4: Pasang `stalwart-cli` dan rekam skema objek sebenarnya

Nama field pada objek konfigurasi Stalwart v0.16 harus diambil dari server yang berjalan, bukan ditebak. Hasil task ini jadi rujukan untuk semua plan di task berikutnya.

**Files:**
- Create: `scripts/lib/cli.sh`
- Create: `docs/reference/stalwart-schema.md`

**Interfaces:**
- Consumes: `load_env` dari Task 2, container hidup dari Task 3
- Produces: `scripts/lib/cli.sh` mengekspor fungsi `swcli <args...>` yang menjalankan `stalwart-cli` dengan `--url http://127.0.0.1:8080 --user admin --password "$STALWART_ADMIN_PASS"`.

- [ ] **Step 1: Pasang CLI di server**

```bash
curl --proto '=https' --tlsv1.2 -LsSf \
  https://github.com/stalwartlabs/cli/releases/latest/download/stalwart-cli-installer.sh | sh
stalwart-cli --help
```

Expected: bantuan CLI tercetak dan memuat subcommand `describe`, `query`, `apply`, `snapshot`.

- [ ] **Step 2: Tulis `scripts/lib/cli.sh`**

```bash
#!/usr/bin/env bash
# Thin wrapper so every script talks to the local admin endpoint the same way.

STALWART_URL="${STALWART_URL:-http://127.0.0.1:8080}"

swcli() {
  stalwart-cli --url "$STALWART_URL" \
    --user admin --password "$STALWART_ADMIN_PASS" "$@"
}
```

- [ ] **Step 3: Buktikan CLI tersambung**

```bash
source scripts/lib/env.sh && load_env
source scripts/lib/cli.sh
swcli query Domain --json
```

Expected: JSON (boleh daftar kosong). Kalau 401, `STALWART_ADMIN_PASS` di `.env` tidak cocok dengan yang dipakai container — restart container setelah `.env` benar.

- [ ] **Step 4: Rekam skema objek yang dipakai plan**

```bash
for obj in Domain Account Listener DkimSignature AcmeProvider DnsServer SystemSettings; do
  echo "===== $obj ====="
  swcli describe "$obj" --json
done > /tmp/schema-dump.txt
swcli snapshot --output /tmp/baseline-snapshot.json
```

- [ ] **Step 5: Tulis `docs/reference/stalwart-schema.md`**

Isi dengan, untuk setiap objek di Step 4: nama properti persis, tipe, mana yang wajib, nilai enum yang valid (khususnya `challengeType`, jenis `Listener`, dan mode `certificateManagement`), serta nama field kredensial pada `DnsServer` untuk Cloudflare dan field relay/smart-host pada objek pengiriman. Kutip nama field apa adanya dari `describe` — dokumen ini yang jadi sumber kebenaran saat menulis `plan.json.tpl`.

Sertakan juga contoh satu objek dari `/tmp/baseline-snapshot.json` untuk setiap tipe, supaya bentuk nyatanya terlihat.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/cli.sh docs/reference/stalwart-schema.md
git commit -m "docs: record stalwart v0.16 object schema from live server"
```

---

### Task 5: Plan deklaratif — domain, akun, dan DKIM

**Files:**
- Create: `config/plan.json.tpl`
- Create: `scripts/render-plan.sh`
- Create: `scripts/apply-plan.sh`
- Test: `tests/render.bats`

**Interfaces:**
- Consumes: `load_env` (Task 2), `swcli` (Task 4), nama field dari `docs/reference/stalwart-schema.md`
- Produces: `config/plan.json` (hasil render, mode 600, tidak di-commit); `scripts/apply-plan.sh` menerapkannya lewat `swcli apply --file config/plan.json`.

- [ ] **Step 1: Tulis test yang gagal**

Buat `tests/render.bats`:

```bash
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
```

- [ ] **Step 2: Jalankan test, pastikan gagal**

Run: `bats tests/render.bats`
Expected: FAIL — `config/plan.json.tpl` dan `scripts/render-plan.sh` belum ada.

- [ ] **Step 3: Tulis `config/plan.json.tpl` (tahap domain + akun)**

Satu operasi per baris, tanpa array pembungkus. Sesuaikan nama field dengan `docs/reference/stalwart-schema.md` bila berbeda.

```
{"@type":"upsert","object":"Domain","matchOn":["name"],"value":{"dom-1":{"name":"${MAIL_DOMAIN_1}"},"dom-2":{"name":"${MAIL_DOMAIN_2}"}}}
{"@type":"update","object":"SystemSettings","value":{"defaultDomainId":"#dom-1"}}
{"@type":"upsert","object":"Account","matchOn":["name"],"value":{"acc-user":{"@type":"Individual","name":"${MAIL_USER_1}","description":"Mailbox pribadi","secrets":["${MAIL_USER_1_PASS}"],"emails":["${MAIL_USER_1}"]},"acc-app":{"@type":"Individual","name":"${MAIL_APP_USER}","description":"Akun aplikasi transaksional","secrets":["${MAIL_APP_PASS}"],"emails":["${MAIL_APP_USER}"]}}}
{"@type":"upsert","object":"DkimSignature","matchOn":["domainId","selector"],"value":{"dkim-1":{"domainId":"#dom-1","selector":"stalwart","algorithm":"Ed25519"},"dkim-2":{"domainId":"#dom-2","selector":"stalwart","algorithm":"Ed25519"}}}
```

- [ ] **Step 4: Tulis `scripts/render-plan.sh`**

```bash
#!/usr/bin/env bash
# Renders the declarative plan template with values from .env.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/env.sh
load_env

# Only substitute the variables we own, so any literal $ in the template survives.
VARS='${MAIL_HOSTNAME} ${MAIL_DOMAIN_1} ${MAIL_DOMAIN_2} ${MAIL_ADMIN_EMAIL} ${MAIL_USER_1} ${MAIL_USER_1_PASS} ${MAIL_APP_USER} ${MAIL_APP_PASS} ${CF_API_TOKEN} ${RESEND_API_KEY}'

umask 077
envsubst "$VARS" < config/plan.json.tpl > config/plan.json
chmod 600 config/plan.json

if grep -q '\${' config/plan.json; then
  echo "masih ada placeholder yang belum tergantikan di config/plan.json" >&2
  exit 1
fi
echo "config/plan.json siap ($(wc -l < config/plan.json) operasi)"
```

Catatan: `envsubst` butuh paket `gettext` (macOS: `brew install gettext`; Debian/Ubuntu: `apt-get install -y gettext-base`).

- [ ] **Step 5: Tulis `scripts/apply-plan.sh`**

```bash
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
```

- [ ] **Step 6: Jalankan test, pastikan lulus**

Run: `bats tests/render.bats`
Expected: 4 tests, 0 failures

- [ ] **Step 7: Terapkan di server dan verifikasi objeknya ada**

```bash
make plan
source scripts/lib/env.sh && load_env && source scripts/lib/cli.sh
swcli query Domain --json
swcli query Account --json
swcli query DkimSignature --json
```

Expected: dua Domain, dua Account (nama berupa alamat email lengkap), dua DkimSignature.

- [ ] **Step 8: Uji login IMAP dengan akun yang baru dibuat**

```bash
docker exec stalwart sh -c 'true'  # pastikan container hidup
openssl s_client -connect 127.0.0.1:993 -quiet 2>/dev/null <<EOF
a LOGIN ${MAIL_USER_1} ${MAIL_USER_1_PASS}
a LOGOUT
EOF
```

Expected: baris `a OK` setelah LOGIN. Kalau listener 993 belum aktif, ini gagal — itu wajar, listener dikonfigurasi di Task 6; ulangi langkah ini setelah Task 6 selesai dan catat hasilnya di sana.

- [ ] **Step 9: Commit**

```bash
git add config/plan.json.tpl scripts/render-plan.sh scripts/apply-plan.sh tests/render.bats
git commit -m "feat: add declarative plan for domains, accounts, and dkim"
```

---

### Task 6: Listener dan TLS otomatis lewat ACME DNS-01 Cloudflare

**Files:**
- Modify: `config/plan.json.tpl` (tambah blok Listener, DnsServer, AcmeProvider, dan pengaturan sertifikat domain)
- Test: `tests/render.bats` (tambah kasus)

**Interfaces:**
- Consumes: `#dom-1` / `#dom-2` dari Task 5, nama field dari `docs/reference/stalwart-schema.md`
- Produces: client id `#dns-cf` (DnsServer Cloudflare) dan `#acme-le` (AcmeProvider Let's Encrypt) untuk dirujuk objek lain; listener aktif di 25, 465, 587, 993, dan HTTP di 127.0.0.1:8080.

- [ ] **Step 1: Tulis test yang gagal**

Tambahkan ke `tests/render.bats`:

```bash
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
```

- [ ] **Step 2: Jalankan test, pastikan gagal**

Run: `bats tests/render.bats`
Expected: 3 test baru FAIL (grep tidak menemukan port dan token).

- [ ] **Step 3: Tambahkan blok berikut ke `config/plan.json.tpl`**

Letakkan setelah baris Domain (objek induk harus lebih dulu). Cocokkan nama field dengan `docs/reference/stalwart-schema.md`; yang di bawah ini mengikuti nama yang didokumentasikan Stalwart.

```
{"@type":"upsert","object":"DnsServer","matchOn":["name"],"value":{"dns-cf":{"name":"cloudflare","@type":"Cloudflare","apiToken":"${CF_API_TOKEN}"}}}
{"@type":"upsert","object":"AcmeProvider","matchOn":["name"],"value":{"acme-le":{"name":"letsencrypt","directory":"https://acme-v02.api.letsencrypt.org/directory","challengeType":"Dns01","contact":{"${MAIL_ADMIN_EMAIL}":true},"renewBefore":"R23"}}}
{"@type":"update","object":"Domain","id":"#dom-1","value":{"certificateManagement":"Automatic","acmeProviderId":"#acme-le","dnsServerId":"#dns-cf","origin":"${MAIL_DOMAIN_1}"}}
{"@type":"update","object":"Domain","id":"#dom-2","value":{"certificateManagement":"Automatic","acmeProviderId":"#acme-le","dnsServerId":"#dns-cf","origin":"${MAIL_DOMAIN_2}"}}
{"@type":"upsert","object":"Listener","matchOn":["name"],"value":{"lsn-smtp":{"name":"smtp","protocol":"Smtp","bindAddress":"0.0.0.0","port":25,"tls":"Optional"},"lsn-submissions":{"name":"submissions","protocol":"Smtp","bindAddress":"0.0.0.0","port":465,"tls":"Implicit"},"lsn-submission":{"name":"submission","protocol":"Smtp","bindAddress":"0.0.0.0","port":587,"tls":"Required"},"lsn-imaps":{"name":"imaps","protocol":"Imap","bindAddress":"0.0.0.0","port":993,"tls":"Implicit"},"lsn-http":{"name":"http","protocol":"Http","bindAddress":"127.0.0.1","port":8080,"tls":"Disabled"}}}
```

- [ ] **Step 4: Jalankan test, pastikan lulus**

Run: `bats tests/render.bats`
Expected: seluruh test lulus (7 test).

- [ ] **Step 5: Pasang A record dan terapkan plan**

Di Cloudflare, tambahkan `A mail → <IP_SERVER>`, DNS-only (grey cloud). Lalu:

```bash
make plan
```

- [ ] **Step 6: Tunggu sertifikat terbit lalu verifikasi**

```bash
sleep 90
docker compose logs --tail=100 | grep -i acme
openssl s_client -connect ${MAIL_HOSTNAME}:465 -servername ${MAIL_HOSTNAME} </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -dates
```

Expected: subject memuat `${MAIL_HOSTNAME}`, issuer Let's Encrypt, tanggal masih berlaku.

Kalau ACME gagal: cek log untuk error otorisasi Cloudflare. Penyebab paling umum adalah token tanpa izin `Zone:DNS:Edit` pada zona tersebut.

- [ ] **Step 7: Ulangi uji login IMAP dari Task 5 Step 8**

Run: perintah `openssl s_client -connect ${MAIL_HOSTNAME}:993` dengan LOGIN seperti pada Task 5 Step 8.
Expected: `a OK` — akun bisa login lewat IMAP TLS dengan sertifikat tepercaya.

- [ ] **Step 8: Commit**

```bash
git add config/plan.json.tpl tests/render.bats
git commit -m "feat: add listeners and acme dns-01 certificates via cloudflare"
```

---

### Task 7: Admin UI di balik nginx dengan pembatasan IP

**Files:**
- Create: `nginx/mail.conf`
- Create: `docs/nginx-setup.md`

**Interfaces:**
- Consumes: HTTP listener `127.0.0.1:8080` dari Task 6, `ADMIN_ALLOW_IP` dari `.env`
- Produces: admin UI dapat diakses di `https://${MAIL_HOSTNAME}/` hanya dari IP yang diizinkan.

- [ ] **Step 1: Tulis `nginx/mail.conf`**

```nginx
# Admin UI for Stalwart. Ganti MAIL_HOSTNAME dan ADMIN_ALLOW_IP sesuai .env.
server {
    listen 443 ssl;
    http2 on;
    server_name MAIL_HOSTNAME;

    ssl_certificate     /etc/letsencrypt/live/MAIL_HOSTNAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/MAIL_HOSTNAME/privkey.pem;

    # Admin surface is never open to the internet at large.
    allow ADMIN_ALLOW_IP;
    deny all;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # JMAP uses long-lived connections for push.
        proxy_http_version 1.1;
        proxy_read_timeout 300s;
    }
}
```

- [ ] **Step 2: Pasang di server**

```bash
source scripts/lib/env.sh && load_env
sed -e "s/MAIL_HOSTNAME/${MAIL_HOSTNAME}/g" -e "s/ADMIN_ALLOW_IP/${ADMIN_ALLOW_IP}/g" \
  nginx/mail.conf | sudo tee /etc/nginx/sites-available/mail.conf
sudo ln -sf /etc/nginx/sites-available/mail.conf /etc/nginx/sites-enabled/mail.conf
sudo certbot certonly --nginx -d "${MAIL_HOSTNAME}" --non-interactive --agree-tos -m "${MAIL_ADMIN_EMAIL}"
sudo nginx -t && sudo systemctl reload nginx
```

Catatan: sertifikat nginx ini terpisah dari sertifikat Stalwart. Stalwart mengurus sertifikatnya sendiri lewat ACME DNS-01; nginx pakai certbot seperti vhost lain di server ini. Tidak ada file yang dipakai bersama, jadi renew salah satu tidak mengganggu yang lain.

- [ ] **Step 3: Verifikasi akses**

Dari IP yang diizinkan: `curl -sI https://${MAIL_HOSTNAME}/ | head -1`
Expected: `HTTP/2 200`

Dari IP lain (misalnya lewat ponsel dengan data seluler): buka URL yang sama.
Expected: `403 Forbidden`.

- [ ] **Step 4: Tulis `docs/nginx-setup.md`**

Catat: perintah pemasangan pada Step 2, cara menambah IP baru ke allowlist (tambahkan baris `allow <ip>;` sebelum `deny all;` lalu `nginx -t && systemctl reload nginx`), dan penegasan bahwa port 8080 tidak boleh dipublikasikan di `docker-compose.yml`.

- [ ] **Step 5: Commit**

```bash
git add nginx/mail.conf docs/nginx-setup.md
git commit -m "feat: serve admin ui through nginx with ip allowlist"
```

---

### Task 8: Outbound lewat relay Resend

**Files:**
- Modify: `config/plan.json.tpl` (tambah konfigurasi relay)
- Create: `scripts/dns-records.sh`
- Test: `tests/dns.bats`

**Interfaces:**
- Consumes: `RESEND_API_KEY` dari `.env`, akun dari Task 5
- Produces: seluruh email keluar dikirim ke `smtp.resend.com:465` dengan username `resend`; `scripts/dns-records.sh` mencetak daftar record DNS yang harus dipasang.

- [ ] **Step 1: Verifikasi domain di Resend**

Di dashboard Resend: Domains → Add Domain untuk `${MAIL_DOMAIN_1}` dan `${MAIL_DOMAIN_2}`. Catat record DKIM dan SPF yang mereka berikan. Ini wajib — mengirim lewat relay tanpa verifikasi domain membuat DMARC gagal walaupun emailnya terkirim.

- [ ] **Step 2: Tulis test yang gagal**

Buat `tests/dns.bats`:

```bash
#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$TMP/scripts/lib"
  cp "$REPO_ROOT"/scripts/lib/*.sh "$TMP/scripts/lib/"
  cp "$REPO_ROOT/scripts/dns-records.sh" "$TMP/scripts/"
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

@test "prints an MX record for each domain" {
  run bash -c "cd '$TMP'; bash scripts/dns-records.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"MX"*"a.com"* ]]
  [[ "$output" == *"MX"*"b.com"* ]]
}

@test "spf points at resend, not at the server itself" {
  run bash -c "cd '$TMP'; bash scripts/dns-records.sh"
  [[ "$output" == *"include:_spf.resend.com"* ]]
  [[ "$output" != *"v=spf1 mx"* ]]
}

@test "prints a dmarc record starting at p=none" {
  run bash -c "cd '$TMP'; bash scripts/dns-records.sh"
  [[ "$output" == *"v=DMARC1"* ]]
  [[ "$output" == *"p=none"* ]]
}

@test "never prints the cloudflare token or resend key" {
  run bash -c "cd '$TMP'; bash scripts/dns-records.sh"
  [[ "$output" != *"cftoken"* ]]
  [[ "$output" != *"re_key"* ]]
}
```

- [ ] **Step 3: Jalankan test, pastikan gagal**

Run: `bats tests/dns.bats`
Expected: FAIL — `scripts/dns-records.sh` belum ada.

- [ ] **Step 4: Tulis `scripts/dns-records.sh`**

```bash
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
```

- [ ] **Step 5: Jalankan test, pastikan lulus**

Run: `bats tests/dns.bats`
Expected: 4 tests, 0 failures

- [ ] **Step 6: Tambahkan relay ke `config/plan.json.tpl`**

Nama objek dan field diambil dari `docs/reference/stalwart-schema.md` bagian pengiriman/queue. Bentuknya: satu operasi `upsert` untuk host relay (host `smtp.resend.com`, port 465, TLS implicit, autentikasi username `resend` dengan password `${RESEND_API_KEY}`), lalu satu operasi yang mengarahkan strategi pengiriman default ke host relay tersebut, dirujuk dengan `#relay-resend`.

Contoh bentuk yang diharapkan (sesuaikan nama field bila `describe` menunjukkan yang lain):

```
{"@type":"upsert","object":"RelayHost","matchOn":["name"],"value":{"relay-resend":{"name":"resend","host":"smtp.resend.com","port":465,"tls":"Implicit","authUsername":"resend","authSecret":"${RESEND_API_KEY}"}}}
{"@type":"update","object":"SystemSettings","value":{"defaultRelayHostId":"#relay-resend"}}
```

- [ ] **Step 7: Terapkan dan kirim email uji**

```bash
make plan
source scripts/lib/env.sh && load_env
docker run --rm -i --network host ghcr.io/nicolaka/netshoot \
  swaks --server 127.0.0.1:465 --tls-on-connect \
        --auth-user "$MAIL_USER_1" --auth-password "$MAIL_USER_1_PASS" \
        --from "$MAIL_USER_1" --to "<alamat-gmail-lu>" \
        --header "Subject: uji kirim lewat relay"
```

Expected: transaksi berakhir `250 OK` dan email sampai di Gmail.

- [ ] **Step 8: Periksa header autentikasi di Gmail**

Buka email di Gmail → menu titik tiga → "Show original".
Expected: `SPF: PASS`, `DKIM: PASS`, `DMARC: PASS`.

Kalau DKIM fail: domain belum terverifikasi di Resend atau record DKIM mereka belum dipasang. Kalau DMARC fail padahal SPF/DKIM pass: domain pada d= DKIM tidak selaras dengan domain pengirim — perbaiki di pengaturan domain Resend.

- [ ] **Step 9: Commit**

```bash
git add config/plan.json.tpl scripts/dns-records.sh tests/dns.bats
git commit -m "feat: route outbound mail through resend relay and print dns records"
```

---

### Task 9: Penerimaan email dan pengaturan IMAP client

**Files:**
- Create: `scripts/verify.sh`
- Create: `docs/client-setup.md`
- Test: `tests/verify.bats`

**Interfaces:**
- Consumes: seluruh komponen Task 3–8
- Produces: `make verify` yang melaporkan status lengkap kirim/terima/keamanan; dokumen pengaturan client.

- [ ] **Step 1: Pasang MX record dan uji terima**

Pastikan MX dari `make dns` sudah terpasang di kedua zona, lalu kirim email dari Gmail ke `${MAIL_USER_1}`.

```bash
sleep 30
docker compose logs --tail=50 | grep -i "$MAIL_USER_1"
```

Expected: log memperlihatkan pesan diterima dan disimpan.

- [ ] **Step 2: Baca email itu lewat IMAP**

```bash
source scripts/lib/env.sh && load_env
openssl s_client -connect "${MAIL_HOSTNAME}:993" -quiet 2>/dev/null <<EOF
a LOGIN ${MAIL_USER_1} ${MAIL_USER_1_PASS}
b SELECT INBOX
c FETCH 1 (BODY[HEADER.FIELDS (SUBJECT FROM)])
d LOGOUT
EOF
```

Expected: `b OK` dengan jumlah pesan minimal 1, dan header Subject email uji tercetak.

- [ ] **Step 3: Tulis test yang gagal**

Buat `tests/verify.bats`:

```bash
#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "verify.sh has no syntax errors" {
  run bash -n "$REPO_ROOT/scripts/verify.sh"
  [ "$status" -eq 0 ]
}

@test "verify.sh performs an explicit open-relay test" {
  run grep -c 'open.relay\|open_relay' "$REPO_ROOT/scripts/verify.sh"
  [ "$output" -gt 0 ]
}

@test "verify.sh checks inbound port 25, tls, and imap login" {
  grep -q 'port 25' "$REPO_ROOT/scripts/verify.sh"
  grep -q '993' "$REPO_ROOT/scripts/verify.sh"
  grep -q 'x509' "$REPO_ROOT/scripts/verify.sh"
}
```

- [ ] **Step 4: Jalankan test, pastikan gagal**

Run: `bats tests/verify.bats`
Expected: FAIL — `scripts/verify.sh` belum ada.

- [ ] **Step 5: Tulis `scripts/verify.sh`**

```bash
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
```

- [ ] **Step 6: Jalankan test, pastikan lulus**

Run: `bats tests/verify.bats`
Expected: 3 tests, 0 failures

- [ ] **Step 7: Jalankan verifikasi asli di server**

Run: `make verify`
Expected: seluruh baris OK, exit 0. Perbaiki setiap FAIL sebelum lanjut — khususnya open relay, yang harus ditangani sebelum server dibiarkan menyala.

- [ ] **Step 8: Tulis `docs/client-setup.md`**

Isi dengan tabel pengaturan: IMAP host `${MAIL_HOSTNAME}` port 993 SSL/TLS, SMTP host `${MAIL_HOSTNAME}` port 465 SSL/TLS, username berupa alamat email lengkap, autentikasi password normal. Tambahkan catatan bahwa port 587 juga tersedia dengan STARTTLS untuk client yang tidak mendukung implicit TLS, dan langkah ringkas untuk Apple Mail, Thunderbird, serta iOS/Android.

- [ ] **Step 9: Commit**

```bash
git add scripts/verify.sh docs/client-setup.md tests/verify.bats
git commit -m "feat: add end-to-end verification and client setup docs"
```

---

### Task 10: Batas laju untuk akun aplikasi

**Files:**
- Modify: `config/plan.json.tpl` (tambah rate limit untuk `#acc-app`)
- Create: `docs/app-integration.md`

**Interfaces:**
- Consumes: `#acc-app` dari Task 5
- Produces: akun aplikasi dengan kuota pengiriman terpisah; contoh kode pengiriman untuk backend.

- [ ] **Step 1: Tambahkan rate limit ke `config/plan.json.tpl`**

Ambil nama objek dan field dari `docs/reference/stalwart-schema.md` bagian rate limit. Targetkan ke `#acc-app` dengan kuota 200 pesan per jam — jauh di atas kebutuhan puluhan/hari, tapi cukup rendah untuk memotong blast kalau kredensialnya bocor.

Bentuk yang diharapkan:

```
{"@type":"upsert","object":"RateLimit","matchOn":["name"],"value":{"rl-app":{"name":"app-outbound","accountId":"#acc-app","messages":200,"period":"1h"}}}
```

- [ ] **Step 2: Terapkan**

Run: `make plan`
Expected: apply sukses dua kali (idempoten).

- [ ] **Step 3: Buktikan akun aplikasi bisa mengirim**

```bash
source scripts/lib/env.sh && load_env
docker run --rm -i --network host ghcr.io/nicolaka/netshoot \
  swaks --server 127.0.0.1:587 --tls \
        --auth-user "$MAIL_APP_USER" --auth-password "$MAIL_APP_PASS" \
        --from "$MAIL_APP_USER" --to "<alamat-gmail-lu>" \
        --header "Subject: uji kirim dari akun aplikasi"
```

Expected: `250 OK`, email sampai, header menunjukkan pengirim `${MAIL_APP_USER}`.

- [ ] **Step 4: Buktikan akun aplikasi tidak bisa membaca mailbox pribadi**

```bash
openssl s_client -connect "${MAIL_HOSTNAME}:993" -quiet 2>/dev/null <<EOF
a LOGIN ${MAIL_APP_USER} ${MAIL_APP_PASS}
b SELECT INBOX
b LOGOUT
EOF
```

Expected: login berhasil tapi INBOX yang terbuka adalah milik akun aplikasi sendiri, bukan milik `${MAIL_USER_1}` — jumlah pesannya berbeda dan tidak memuat email uji dari Task 9.

- [ ] **Step 5: Tulis `docs/app-integration.md`**

Isi dengan: host `${MAIL_HOSTNAME}`, port 587 STARTTLS atau 465 implicit TLS, username `${MAIL_APP_USER}`, password dari `.env`, contoh pengiriman dengan nodemailer dan dengan Python `smtplib`, serta catatan bahwa kuota 200 pesan/jam berlaku dan cara menaikkannya (ubah `messages` di `plan.json.tpl` lalu `make plan`).

- [ ] **Step 6: Commit**

```bash
git add config/plan.json.tpl docs/app-integration.md
git commit -m "feat: rate limit the application account and document integration"
```

---

### Task 11: Inbound ke aplikasi — webhook dan polling IMAP

**Files:**
- Modify: `config/plan.json.tpl` (tambah objek webhook, dimatikan secara default)
- Modify: `.env.example` (tambah `WEBHOOK_URL`)
- Modify: `scripts/lib/env.sh` (jadikan `WEBHOOK_URL` opsional)
- Create: `docs/inbound-processing.md`
- Test: `tests/render.bats` (tambah kasus)

**Interfaces:**
- Consumes: `load_env` dari Task 2
- Produces: jalur webhook yang bisa dinyalakan dengan mengisi `WEBHOOK_URL` di `.env`; dokumentasi jalur alternatif berupa polling IMAP.

- [ ] **Step 1: Tulis test yang gagal**

Tambahkan ke `tests/render.bats`:

```bash
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
```

- [ ] **Step 2: Jalankan test, pastikan gagal**

Run: `bats tests/render.bats`
Expected: test kedua FAIL (webhook belum pernah dirender).

- [ ] **Step 3: Tambahkan blok webhook opsional**

Di `config/plan.json.tpl`, taruh baris webhook dalam file terpisah `config/plan.webhook.tpl`:

```
{"@type":"upsert","object":"Webhook","matchOn":["name"],"value":{"wh-inbound":{"name":"inbound-app","url":"${WEBHOOK_URL}","events":["message.accepted"]}}}
```

Lalu di `scripts/render-plan.sh`, tepat sebelum pemeriksaan placeholder, tambahkan:

```bash
# The webhook path is opt-in: only rendered when the app endpoint is configured.
if [ -n "${WEBHOOK_URL:-}" ]; then
  envsubst '${WEBHOOK_URL}' < config/plan.webhook.tpl >> config/plan.json
fi
```

Tambahkan `WEBHOOK_URL` ke `.env.example` dengan nilai kosong dan komentar bahwa mengosongkannya berarti webhook mati. Jangan tambahkan ke `REQUIRED_VARS` di `scripts/lib/env.sh` — variabel ini opsional.

- [ ] **Step 4: Jalankan test, pastikan lulus**

Run: `bats tests/render.bats`
Expected: seluruh test lulus (9 test).

- [ ] **Step 5: Uji webhook dengan endpoint penampung**

```bash
# Terminal 1 di server: penampung sementara.
docker run --rm -p 9000:8080 ghcr.io/tarampampam/webhook-tester:latest
# Isi WEBHOOK_URL=http://127.0.0.1:9000/ di .env lalu:
make plan
# Kirim email dari Gmail ke ${MAIL_USER_1}, lalu lihat terminal 1.
```

Expected: satu POST masuk berisi metadata pesan.

Kalau nama field objek Webhook berbeda dari yang ditulis di Step 3, perbaiki sesuai `swcli describe Webhook --json` dan catat di `docs/reference/stalwart-schema.md`.

- [ ] **Step 6: Tulis `docs/inbound-processing.md`**

Isi dengan dua jalur: (1) webhook — cara mengisi `WEBHOOK_URL`, bentuk payload yang benar-benar diterima pada Step 5, dan catatan bahwa endpoint harus idempoten karena pengiriman ulang mungkin terjadi; (2) polling IMAP — contoh Python `imaplib` yang login sebagai akun khusus, membaca pesan `UNSEEN`, memprosesnya, lalu menandainya `\Seen`, beserta alasan memilih jalur ini (tidak butuh endpoint publik).

- [ ] **Step 7: Commit**

```bash
git add config/plan.json.tpl config/plan.webhook.tpl scripts/render-plan.sh scripts/lib/env.sh .env.example docs/inbound-processing.md tests/render.bats
git commit -m "feat: add optional inbound webhook and document imap polling path"
```

---

### Task 12: README dan pemeriksaan akhir

**Files:**
- Create: `README.md`
- Modify: `docs/reference/stalwart-schema.md` (rapikan sesuai temuan nyata)

**Interfaces:**
- Consumes: seluruh task sebelumnya
- Produces: dokumentasi masuk untuk orang yang baru membuka repo ini.

- [ ] **Step 1: Tulis `README.md`**

Struktur: apa ini dan untuk siapa; persyaratan (VPS 2 GB, Docker, nginx, domain di Cloudflare, akun Resend); langkah pemasangan dari nol dalam urutan `cp .env.example .env` → isi → `make preflight` → `make up` → `make dns` → pasang record → `make plan` → `make verify`; tabel target Make; peringatan bahwa port 25 outbound diblokir provider sehingga pengiriman lewat Resend; tautan ke `docs/client-setup.md`, `docs/app-integration.md`, `docs/inbound-processing.md`, `docs/nginx-setup.md`, dan spec desain.

- [ ] **Step 2: Uji ulang seluruh unit test**

Run: `make test`
Expected: seluruh file bats lulus, 0 failures.

- [ ] **Step 3: Jalankan verifikasi penuh sekali lagi**

Run: `make verify`
Expected: exit 0, tidak ada FAIL.

- [ ] **Step 4: Pastikan tidak ada rahasia yang ter-commit**

```bash
git ls-files | xargs grep -lE 'RESEND_API_KEY=re_|CF_API_TOKEN=[A-Za-z0-9_-]{20,}|STALWART_ADMIN_PASS=[A-Za-z0-9]{8,}' || echo "bersih"
git check-ignore -v .env config/plan.json
```

Expected: baris pertama mencetak `bersih`; baris kedua menunjukkan keduanya diabaikan `.gitignore`.

- [ ] **Step 5: Commit**

```bash
git add README.md docs/reference/stalwart-schema.md
git commit -m "docs: add readme and finalize schema reference"
```

---

## Catatan Eksekusi

- **Task 1 adalah gerbang.** Kalau port 25 inbound tidak bisa dijangkau setelah security group Tencent dibuka, hentikan pekerjaan dan laporkan — spec ini mengasumsikan penerimaan di-self-host.
- **Task 4 memberi makan Task 5, 6, 8, 10, dan 11.** Semua nama field pada plan JSON harus dicocokkan dengan `docs/reference/stalwart-schema.md` yang dihasilkan dari server sungguhan. Kalau ada yang berbeda dari contoh di plan ini, yang menang adalah keluaran `swcli describe`, dan perbedaannya dicatat di dokumen itu.
- **Setiap `make plan` dijalankan dua kali** oleh `apply-plan.sh` untuk membuktikan idempotensi. Kalau kali kedua mengubah sesuatu, ada operasi yang bukan `upsert` — perbaiki templatenya.
- **Uji open relay pada Task 9 tidak boleh dilewati.** Server yang jadi open relay akan masuk blocklist dalam hitungan jam dan menyeret reputasi kedua domain.
