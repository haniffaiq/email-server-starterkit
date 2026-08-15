# Mail Server Starter — Email Server Mandiri

Ini adalah starter repo untuk menjalankan mail server sendiri di VPS terjangkau (2 GB RAM). Menerima email langsung di port 25, mengirim melalui relay Resend, dan melayani tiga kebutuhan sekaligus:

1. **Mailbox pribadi** — baca email dengan IMAP client
2. **Relay transaksional** — kirim email dari aplikasi (notifikasi, reset password)
3. **Inbound processing** — terima email masuk di aplikasi via webhook atau polling IMAP

## Untuk Siapa?

Repo ini cocok untuk Anda jika:
- Punya VPS sendiri yang tidak pakai 2 GB RAM untuk hal lain
- Ingin mengontrol infrastruktur email sendiri (bukan depend ke Gmail/Mailgun)
- Butuh email transaksional realtime tanpa API query lag
- Punya domain di Cloudflare dan akun Resend
- Nyaman dengan command line dan Docker

**Bukan untuk Anda jika:** Anda butuh webmail, archive puluhan tahun, atau tolerance 99.95% (single server tidak cocok).

## Persyaratan

| Komponen | Spesifikasi | Catatan |
|----------|-------------|--------|
| **VPS** | 2 GB RAM, 2 core, 30 GB disk | Tested di Tencent Lighthouse SG/HK/JKT |
| **Port inbound** | TCP 25, 465, 587, 993 terbuka | Kalau 25 diblokir, setup tidak bisa dilanjutkan |
| **OS** | Ubuntu 20.04+ atau Debian 11+ | Harus support Docker |
| **Docker** | 20.10+ dengan Docker Compose **v2 plugin** | `apt install docker.io docker-compose-plugin` — harus perintah `docker compose` (dua kata), bukan `docker-compose` (v1) lama. `scripts/preflight.sh` mengecek keberadaan plugin ini, bukan binary v1 |
| **stalwart-cli** | Binary CLI terpisah dari image server | Lihat perintah instalasi di bawah — **tidak** disertakan di dalam image `stalwartlabs/stalwart` |
| **gettext-base** | Menyediakan `envsubst` | Dipakai `scripts/render-plan.sh` untuk render `plan.json.tpl` |
| **python3** | Interpreter Python 3 | Dipakai `scripts/render-plan.sh` untuk JSON-escape secrets dan memvalidasi tiap baris hasil render. Biasanya sudah terpasang di Ubuntu/Debian, tapi **jangan diasumsikan** — cek dengan `python3 --version` |
| **jq** | JSON processor | Dipakai `scripts/dns-records.sh` untuk memproyeksikan output DKIM (public key saja) supaya private key tidak pernah tercetak ke stdout |
| **dnsutils** | Menyediakan `dig` | Dipakai `scripts/dns-records.sh` dan `scripts/verify.sh` |
| **netcat-openbsd** | Menyediakan `nc` | Dipakai `scripts/verify.sh` (open-relay test) dan cek port 25 manual |
| **swaks** | Swiss Army Knife for SMTP | Dipakai untuk uji kirim email manual (lihat bagian `make verify`) |
| **bats** | Opsional | Hanya perlu kalau Anda mau menjalankan test milik repo ini sendiri (`make test`) |
| **Nginx** | Sudah terpasang | Buat vhost tambahan untuk admin UI |
| **Domain** | 1-2 domain di Cloudflare (DNS only) | Dapat mengedit DNS dan API token |
| **Resend** | Akun aktif + API key | relay outbound; free tier 3.000/bulan |

Instalasi cepat dependency di Ubuntu/Debian:

```bash
sudo apt update
sudo apt install -y docker.io docker-compose-plugin gettext-base python3 jq dnsutils netcat-openbsd swaks
# bats opsional, hanya jika ingin menjalankan `make test`
sudo apt install -y bats

# stalwart-cli: installer resmi upstream (host binary, bukan bagian image server)
curl --proto '=https' --tlsv1.2 -LsSf https://github.com/stalwartlabs/cli/releases/latest/download/stalwart-cli-installer.sh | sh
```

### Pemeriksaan Awal

Sebelum mulai, pastikan:

```bash
# Docker Compose harus plugin v2 (perintah "docker compose", dua kata)
docker --version && docker compose version

# Swap tersedia (untuk Tencent Lighthouse yang tidak ada default)
free -h

# Sudah ada akun Resend dan domain terverifikasi
# Sudah punya CF_API_TOKEN dengan izin Zone:DNS:Edit
```

Port 25 inbound **tidak bisa** dicek dengan `curl -v telnet://127.0.0.1:25` — itu hanya menguji loopback, dan akan selalu gagal sebelum mail server terpasang (tidak ada apa pun yang mendengarkan di 127.0.0.1:25 sebelum `make up`). Untuk memastikan provider benar-benar meneruskan port 25 inbound ke server ini, jalankan tes dua-mesin sebelum lanjut instalasi:

```bash
# Di server (mesin ini):
sudo nc -l 25

# Dari mesin LAIN (laptop Anda, atau VPS lain), ganti <SERVER_IP>:
nc -vz -w 5 <SERVER_IP> 25
```

Kalau perintah kedua melapor "succeeded" atau "open", port 25 inbound sudah sampai ke server. Kalau timeout/refused, security group provider (lihat catatan firewall di bawah) belum membuka 25 masuk — perbaiki dulu sebelum lanjut.

**⚠️ Port 25 itu satu arah — jangan tertukar:**
- **Outbound port 25 diblokir provider dan memang tidak pernah dipakai.** Semua pengiriman keluar lewat relay Resend (lihat catatan di bawah). Ini permanen, bukan sesuatu yang perlu "dibuka" nanti.
- **Inbound port 25 wajib terbuka.** Ini bukan opsional — setiap mail server lain di internet mengirim ke domain Anda lewat port 25 inbound, sesuai MX record. Port 465/587/993 **tidak menggantikan** port 25 inbound; ketiganya untuk client Anda sendiri (submission/IMAP), bukan untuk menerima mail dari server lain. Kalau 25 inbound diblokir, domain ini tidak akan pernah menerima email masuk, apa pun status 465/587/993.

**⚠️ Catatan penting tentang port 25 outbound:** Tencent Lighthouse (dan kebanyakan provider VPS) **menutup port 25 outbound**. Ini adalah keputusan arsitektur yang permanen — seluruh pengiriman email melewati relay Resend, bukan koneksi langsung ke MX penerima. Jangan rencana workaround untuk "nantinya" — desain aplikasi dan config asumsi relay selamanya.

**⚠️ Catatan firewall:** Docker mempublikasikan port lewat chain DNAT miliknya sendiri di `iptables`, yang **bypass** rule INPUT dari `ufw` atau `iptables` host. Artinya untuk port mail yang dipublikasikan (25/465/587/993), kontrol efektifnya adalah **security group Tencent** (atau firewall level-provider yang setara), bukan `ufw` di dalam server. Mengecek/mengedit `ufw` tidak akan mengubah apakah port-port ini bisa diakses dari luar.

## Setup dari Nol — Langkah demi Langkah

### 1. Clone repo dan copy .env

```bash
cd /opt  # atau lokasi lain di server
git clone https://github.com/yourusername/email-server.git
cd email-server
cp .env.example .env
```

### 2. Edit .env dengan data Anda

```bash
nano .env
```

Minimal yang harus diisi:

```bash
# Domain dan hostname
MAIL_HOSTNAME=mail.domain-utama.com
MAIL_DOMAIN_1=domain-utama.com
MAIL_DOMAIN_2=domain-kedua.com

# Mailbox pribadi (username harus full email)
MAIL_USER_1=your-name@domain-utama.com
MAIL_USER_1_PASS=password-panjang-yang-aman

# Akun aplikasi untuk relay transaksional
MAIL_APP_USER=noreply@domain-utama.com
MAIL_APP_PASS=password-panjang-yang-aman

# Mailbox untuk domain kedua (MAIL_DOMAIN_2) — tanpa ini domain kedua tidak
# punya mailbox sama sekali. Username harus alamat email lengkap di MAIL_DOMAIN_2.
MAIL_USER_2=your-name@domain-kedua.com
MAIL_USER_2_PASS=password-panjang-yang-aman

# Cloudflare API token (izin Zone:DNS:Edit saja)
CF_API_TOKEN=your_cloudflare_api_token_here

# Resend API key
RESEND_API_KEY=re_your_resend_key_here

# Admin UI allowlist (IP yang boleh akses via nginx)
ADMIN_ALLOW_IP=1.2.3.4

# Password admin panel Stalwart — WAJIB diisi manual, lihat langkah generate di bawah
STALWART_ADMIN_PASS=admin-password-anda
```

**⚠️ `STALWART_ADMIN_PASS` tidak auto-generate.** `scripts/lib/env.sh` mewajibkan variabel ini terisi — kalau kosong, `make up` langsung gagal dengan pesan `variabel STALWART_ADMIN_PASS belum diisi di .env`. Generate dan tambahkan sebelum lanjut:

```bash
printf 'STALWART_ADMIN_PASS=%s\n' "$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)" >> .env
```

Setelah menjalankan perintah di atas, buka `.env` dan pastikan **tidak ada baris `STALWART_ADMIN_PASS=` kosong yang tersisa dari sebelumnya** — kalau ada dua baris untuk variabel yang sama, `source` di `scripts/lib/env.sh` memakai assignment yang **terakhir**, jadi baris kosong di bawah baris baru akan diam-diam mengosongkan lagi passwordnya.

### 3. Jalankan preflight checks

```bash
make preflight
```

Ini akan memeriksa:
- Port 25 inbound accessible
- Port 25 outbound blocked (expected)
- RAM dan swap cukup
- Docker running
- Port 25/465/587/993 tidak terpakai

Kalau ada yang merah (FAIL), perbaiki sebelum lanjut. Jika port 25 inbound tidak bisa dijangkau, stop di sini — setup tidak bisa dilanjutkan.

### 4. Jalankan mail server

```bash
make up
```

Ini akan:
- Buat swap 2 GB jika tidak ada
- Pull image Stalwart v0.16
- Start container stalwart
- Tunggu container siap
- Setup admin recovery password

Lihat log untuk memastikan server siap:

```bash
make logs | tail -20
```

Cari baris seperti `Server is ready`.

### 5. ⚠️ PENTING: Record Stalwart Schema

**Sebelum menjalankan `make plan`, Anda harus mencatat schema object Stalwart dari server yang sedang berjalan.** Stalwart v0.16 memindahkan seluruh konfigurasi ke datastore sebagai objek JMAP, dan nama field di `config/plan.json.tpl` di repo ini bersifat **provisional** — diambil dari dokumen perencanaan, belum diverifikasi terhadap server yang sebenarnya. Kalau output live berbeda dari template, **output live yang menang**, bukan template.

Panduan lengkap plus tabel isian ada di **[docs/reference/stalwart-schema.md](docs/reference/stalwart-schema.md)** — baca dan ikuti file itu sebelum lanjut ke `make plan`. Ringkasnya, di server yang sedang berjalan:

```bash
# stalwart-cli adalah host binary terpisah, diakses lewat wrapper swcli
# (scripts/lib/cli.sh) yang menunjuk ke http://127.0.0.1:8080 — BUKAN
# via "docker exec stalwart stalwart-cli ...". Image server dan CLI
# adalah dua artifact berbeda; CLI tidak ada di dalam image server.
source scripts/lib/cli.sh

swcli describe Domain --json > /tmp/domain.json
swcli describe Account --json > /tmp/account.json
swcli describe Listener --json > /tmp/listener.json
swcli describe DkimSignature --json > /tmp/dkim.json
swcli describe AcmeProvider --json > /tmp/acme.json
swcli describe DnsServer --json > /tmp/dns.json
swcli describe RateLimit --json > /tmp/ratelimit.json
swcli describe SystemSettings --json > /tmp/systemsettings.json
# plus object relay/queue (lihat nama pastinya di describe list server Anda)

# Simpan snapshot baseline sebelum apply pertama, untuk pembanding/rollback
swcli snapshot --output baseline.json
```

Isi tabel di `docs/reference/stalwart-schema.md` dengan field yang benar, lalu samakan `config/plan.json.tpl` dengannya sebelum `make plan`.

Ini step manual yang hanya perlu dilakukan sekali untuk server baru (schema tidak berubah lagi setelah dicatat, kecuali ada upgrade Stalwart mayor berikutnya).

### 6. Copy DNS records dan buat di Cloudflare

```bash
make dns
```

Perintah ini mencetak, dalam bentuk siap copy-paste, record A untuk `mail.<domain>`, record MX, TXT SPF, dan TXT DMARC untuk tiap domain di `.env`, diikuti hasil query `DkimSignature` dari server (kalau `stalwart-cli` dan `STALWART_ADMIN_PASS` tersedia) serta pengingat untuk mengambil record DKIM dari dashboard Resend secara terpisah. Format baris persisnya bisa berubah — jalankan sendiri untuk melihat output aktual, lalu tempel setiap record yang tercetak ke Cloudflare (DNS tab, Create record).

Setelah itu:
1. Pastikan "Proxy" = OFF (grey cloud, bukan orange) untuk semua record ini — port 25 mati kalau proxy Cloudflare aktif
2. Verifikasi domain di https://app.resend.com/domains
3. Tunggu DNS propagate (biasanya 5-15 menit)
4. Lalu jalankan next step

Lakukan di Cloudflare dashboard sebelum lanjut.

### 7. Render dan terapkan konfigurasi

```bash
make plan
```

Ini akan:
- Render `config/plan.json.tpl` dari variabel `.env`
- Terapkan ke Stalwart dengan `stalwart-cli apply` (idempoten)
- Jalankan apply dua kali untuk verifikasi idempotency

Jika ada error, periksa:
- Field names di plan.json.tpl cocok dengan schema server (lihat Step 5)
- `.env` terisi lengkap
- Tidak ada placeholder yang tertinggal

### 8. Jalankan automated checks

```bash
make verify
```

**`make verify` bukan end-to-end test kirim/terima email — ia adalah kumpulan health check lokal dan struktural.** Yang benar-benar diperiksa:
- Container `stalwart` jalan
- Ada proses yang mendengarkan di port 25
- Subject sertifikat TLS di port submission cocok dengan `MAIL_HOSTNAME`
- Login IMAP dengan kredensial `MAIL_USER_1` berhasil
- Percobaan relay tanpa autentikasi ke domain asing **ditolak** (open-relay negative test)
- Record MX, SPF, dan DMARC **ada** di DNS untuk tiap domain (bukan diverifikasi PASS/FAIL, hanya dicek keberadaannya)
- Headroom memori container

**Yang TIDAK diperiksa oleh `make verify`:** tidak ada email test yang benar-benar dikirim ke luar, tidak ada penantian delivery, dan tidak ada pengecekan bahwa SPF/DKIM/DMARC benar-benar *pass* saat email diterima penerima nyata. Semua itu hanya bisa dikonfirmasi secara manual, di luar server ini, sebelum go-live.

#### Manual checks sebelum go-live

Lakukan ketiganya sebelum menganggap mail server ini siap produksi:

1. **Kirim dari mailbox ini ke Gmail** memakai client terautentikasi (lihat [docs/client-setup.md](docs/client-setup.md) atau `swaks --to your-gmail@gmail.com --from ${MAIL_APP_USER} --server ${MAIL_HOSTNAME}:587 --tls --auth-user ${MAIL_APP_USER}`), lalu buka email itu di Gmail dan lihat header **Authentication-Results** (Show original) — SPF, DKIM, dan DMARC harus sama-sama `pass`.
2. **Kirim dari Gmail ke mailbox di server ini** dan pastikan email benar-benar sampai ke inbox (bukan cuma "terkirim" di sisi Gmail).
3. **Jalankan tes open-relay eksternal dari luar server**, misalnya lewat [MXToolbox](https://mxtoolbox.com/diagnostic.aspx) atau `mxtoolbox.com/SuperTool.aspx?action=relay%3a` — tes internal di `make verify` hanya membuktikan server ini menolak relay dari loopback-nya sendiri, bukan dari internet.

Semua test otomatis dan manual di atas harus berhasil sebelum go live.

### 9. ⚠️ Keamanan: cabut recovery admin setelah admin normal ada

`docker-compose.yml` men-set `STALWART_RECOVERY_ADMIN` supaya bootstrap awal reproducible. Akun ini **bukan** akun admin biasa: ia bypass sistem akun di datastore, **tidak bisa dimatikan dari UI** selama variabelnya masih di-set, credential-nya terbaca siapa pun yang bisa `docker inspect stalwart`, dan ia **tidak tunduk pada auto-ban policy** normal. Selama variabel ini ada, server ini punya superadmin permanen yang tidak mengikuti kontrol keamanan lain.

Begini urutan yang aman: setelah `make plan` berhasil dan Anda sudah punya akun admin normal (via UI Stalwart atau objek `Account` yang sesuai) dan sudah login-test dengan akun itu, **hapus `STALWART_RECOVERY_ADMIN` dari `docker-compose.yml` dan restart container**:

```bash
# Edit docker-compose.yml, hapus baris STALWART_RECOVERY_ADMIN dari environment:
nano docker-compose.yml

# Lalu restart supaya perubahan environment berlaku
docker compose up -d
```

Ini bukan langkah opsional atau tidy-up — ini adalah langkah keamanan wajib sebelum server dianggap production-ready.

## Make Targets — Daftar Perintah

| Perintah | Kegunaan |
|----------|----------|
| `make help` | Tampilkan daftar ini |
| `make preflight` | Cek persyaratan server (port, RAM, Docker) |
| `make up` | Jalankan mail server (one-time setup) |
| `make plan` | Render dan terapkan config deklaratif |
| `make dns` | Cetak DNS records yang harus dipasang |
| `make verify` | Health check lokal (container, port, TLS, IMAP login, open-relay negative test, keberadaan record DNS) — bukan test kirim/terima end-to-end, lihat langkah 8 di atas |
| `make logs` | Follow container logs (live tail) |
| `make test` | Jalankan unit test render template |

Setelah setup sukses, perintah sehari-hari adalah:

```bash
# Lihat log realtime
make logs

# Jika perlu ubah config (di .env atau plan.json.tpl)
nano .env
make plan

# Jika perlu verify lagi
make verify
```

## Dokumentasi Lanjutan

- **[docs/client-setup.md](docs/client-setup.md)** — Setting IMAP/SMTP untuk Apple Mail, Thunderbird, iOS, dan Android.
- **[docs/app-integration.md](docs/app-integration.md)** — Cara aplikasi mengirim email transaksional. Contoh Node.js dan Python.
- **[docs/inbound-processing.md](docs/inbound-processing.md)** — Terima email masuk di aplikasi via webhook atau polling IMAP. Contoh Python imaplib.
- **[docs/nginx-setup.md](docs/nginx-setup.md)** — Setup nginx reverse proxy untuk admin UI dengan IP allowlist.
- **[docs/reference/stalwart-schema.md](docs/reference/stalwart-schema.md)** — Cara mencatat schema object Stalwart yang sebenarnya dari server, dan tabel isian sebelum `make plan` pertama kali.
- **[docs/superpowers/specs/2026-08-15-email-server-design.md](docs/superpowers/specs/2026-08-15-email-server-design.md)** — Design spec lengkap: arsitektur, keputusan teknis, flow, security model.

## Struktur Repo

```
email-server/
├─ README.md                    # File ini
├─ Makefile                     # Perintah setup dan operasi
├─ docker-compose.yml           # Konfigurasi container
├─ .env.example                 # Template environment variables
├─ .gitignore                   # Abaikan .env, data, plan rendered
├─ config/
│  ├─ config.json               # Stalwart main config (RocksDB datastore)
│  ├─ plan.json.tpl             # Template config deklaratif
│  └─ plan.webhook.tpl          # Template webhook (opsional)
├─ scripts/
│  ├─ preflight.sh              # Cek persyaratan
│  ├─ bootstrap.sh              # Setup initial (swap, folder, UID)
│  ├─ render-plan.sh            # Render plan.json dari .env
│  ├─ apply-plan.sh             # Terapkan dengan stalwart-cli (host binary, via swcli)
│  ├─ dns-records.sh            # Print DNS yang harus dipasang
│  ├─ verify.sh                 # Health check lokal (bukan test kirim/terima end-to-end)
│  └─ lib/
│     ├─ env.sh                 # Helper load environment
│     └─ cli.sh                 # Wrapper swcli (kredensial lewat env STALWART_URL/STALWART_USER/STALWART_PASSWORD, bukan argv)
├─ nginx/
│  └─ mail.conf                 # Vhost admin UI + IP allowlist
├─ tests/
│  └─ render.bats               # Unit test render plan
└─ docs/
   ├─ app-integration.md        # Relay transaksional
   ├─ inbound-processing.md     # Webhook / polling IMAP
   ├─ nginx-setup.md            # Setup admin UI
   ├─ reference/stalwart-schema.md  # Cara mencatat schema live server
   └─ superpowers/specs/        # Design spec
```

## Troubleshooting

### Port 25 inbound tidak bisa dijangkau dari luar
- Untuk port 25/465/587/993 yang dipublikasikan Docker, kontrol efektifnya adalah **security group Tencent**, bukan `ufw`/`iptables` host — Docker mempublikasikan port lewat chain DNAT sendiri yang bypass rule INPUT host. Periksa security group dulu, bukan `ufw status`.
- Cek ISP tidak blok port 25 (unlikely tapi mungkin)
- Test dari mesin lain (bukan loopback server ini): `nc -vz -w 5 mail.domain-utama.com 25` — lihat "Pemeriksaan Awal" di atas untuk tes dua-mesin lengkapnya

### Email tidak terkirim (stuck di outbound)
- Pastikan `RESEND_API_KEY` valid dan domain sudah verified di Resend
- Cek log: `make logs | grep -i resend`
- `make verify` hanya memastikan record SPF/DMARC *ada* di DNS, bukan bahwa pengiriman sudah *pass* — lakukan manual check kirim ke Gmail (lihat Step 8) untuk memastikan status pass sebenarnya

### DKIM/SPF/DMARC dicurigai gagal
- `make verify` **tidak** memeriksa DKIM sama sekali, dan untuk SPF/DMARC hanya memeriksa keberadaan record, bukan hasil pass/fail — jangan andalkan `make verify` untuk mendiagnosis ini
- Tunggu DNS propagate (5-15 menit)
- Cek record di Cloudflare betul dan DNS-only (grey cloud)
- Kirim email nyata ke Gmail dan baca header **Authentication-Results** (Show original) untuk lihat status pass/fail yang sebenarnya — lihat manual checks di Step 8

### Admin UI tidak bisa diakses
- Periksa IP Anda di daftar allow `ADMIN_ALLOW_IP`
- Pastikan nginx sudah disetup: `sudo systemctl status nginx`
- Cek log nginx: `sudo tail -f /var/log/nginx/error.log`

### Kapasitas disk penuh
- Stalwart menyimpan email di RocksDB (`/opt/mail/data/`), periksa ukuran
- Jika disk penuh, backup dan hapus email lama (di luar scope starter ini)

### Container crash atau restart loop
- Cek log: `make logs`
- Periksa RAM (swap) cukup: `free -h`
- Periksa disk tidak penuh: `df -h`
- Jika masalah permanen, rebuild: `docker compose down && make up`

## Operasi Sehari-hari

### Monitor kesehatan

```bash
make logs | tail -50      # Lihat 50 baris terakhir
make verify              # Health check lokal (container, port, TLS, IMAP, open-relay, keberadaan DNS)
docker stats stalwart    # CPU, memory, network usage
```

### Ubah konfigurasi (password, rate limit, webhook)

```bash
# Edit .env atau config/plan.json.tpl
nano .env

# Terapkan perubahan
make plan

# Verifikasi
make verify
```

### Backup

Data email tersimpan di `/opt/mail/` di host:

```bash
sudo tar -czf /backup/mail-backup-$(date +%Y%m%d).tar.gz /opt/mail/
```

(Backup detail di luar scope starter ini.)

## License

MIT — gunakan bebas untuk keperluan pribadi atau komersial.

## Support & Kontribusi

Issue? Baca docs di atas dulu, terutama design spec. Kalau masalah di Step 5 (schema reconciliation), lihat [docs/reference/stalwart-schema.md](docs/reference/stalwart-schema.md), jalankan `swcli describe <Object> --json` (lihat `scripts/lib/cli.sh`) di server, dan samakan field names di `config/plan.json.tpl`.

Kontribusi welcome: fork, buat branch, commit dengan pesan jelas, push, buat pull request.

---

**Terakhir di-update:** 2026-08-15  
**Stalwart version:** v0.16  
**Tested di:** Tencent Cloud Lighthouse (SG/HK/JKT), 2GB RAM, Ubuntu 22.04
