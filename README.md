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
| **Docker** | 20.10+ dengan docker-compose | `apt install docker.io docker-compose` |
| **Nginx** | Sudah terpasang | Buat vhost tambahan untuk admin UI |
| **Domain** | 1-2 domain di Cloudflare (DNS only) | Dapat mengedit DNS dan API token |
| **Resend** | Akun aktif + API key | relay outbound; free tier 3.000/bulan |

### Pemeriksaan Awal

Sebelum mulai, pastikan:

```bash
# Port 25 inbound accessible
curl -v telnet://127.0.0.1:25

# Docker tersedia
docker --version && docker-compose --version

# Swap tersedia (untuk Tencent Lighthouse yang tidak ada default)
free -h

# Sudah ada akun Resend dan domain terverifikasi
# Sudah punya CF_API_TOKEN dengan izin Zone:DNS:Edit
```

**⚠️ Catatan penting tentang port 25 outbound:** Tencent Lighthouse (dan kebanyakan provider VPS) **menutup port 25 outbound**. Ini adalah keputusan arsitektur yang permanen — seluruh pengiriman email melewati relay Resend, bukan koneksi langsung ke MX penerima. Jangan rencana workaround untuk "nantinya" — desain aplikasi dan config asumsi relay selamanya.

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

# Cloudflare API token (izin Zone:DNS:Edit saja)
CF_API_TOKEN=your_cloudflare_api_token_here

# Resend API key
RESEND_API_KEY=re_your_resend_key_here

# Admin UI allowlist (IP yang boleh akses via nginx)
ADMIN_ALLOW_IP=1.2.3.4

# Password admin panel Stalwart (auto-generated jika kosong)
STALWART_ADMIN_PASS=admin-password-anda
```

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

### 5. ⚠️ PENTING: Record Stalwart Schema (Task 4)

**Sebelum menjalankan `make plan`, Anda harus mencatat schema object Stalwart dari server yang sedang berjalan.** Ini karena Stalwart v0.16 mengganti nama beberapa field, dan template plan.json harus cocok persis dengan server.

Jalankan di server:

```bash
docker exec stalwart stalwart-cli describe Domain --json > /tmp/domain.json
docker exec stalwart stalwart-cli describe Account --json > /tmp/account.json
docker exec stalwart stalwart-cli describe Listener --json > /tmp/listener.json
# ... (describe semua object type yang dipakai)
```

Lihat output dan bandingkan dengan field yang dipakai di `config/plan.json.tpl`. Kalau ada yang berbeda, catat perbedaannya agar next step `make plan` sukses.

Ini step manual yang hanya perlu dilakukan sekali untuk server baru.

### 6. Copy DNS records dan buat di Cloudflare

```bash
make dns
```

Ini mencetak record MX, SPF, DKIM, dan DMARC yang harus dipasang. Contoh output:

```
Copy these records to Cloudflare for mail.domain-utama.com:

A record:
  mail.domain-utama.com  A  203.0.113.50

MX record:
  @  MX 10 mail.domain-utama.com

SPF record:
  @  TXT  v=spf1 include:_spf.resend.com -all

DKIM record (dari Resend):
  resend._domainkey  TXT  (copy dari halaman verifikasi Resend)

DMARC record:
  _dmarc  TXT  v=DMARC1; p=none; rua=mailto:dmarc@domain-utama.com

---

Jangan lupa:
1. Tempel semua record di atas ke Cloudflare (DNS tab, Create record)
2. Pastikan "Proxy" = OFF (grey cloud, bukan orange), port 25 mati kalau proxy aktif
3. Verifikasi domain di https://app.resend.com/domains
4. Tunggu DNS propagate (biasanya 5-15 menit)
5. Lalu jalankan next step
```

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

### 8. Verifikasi email bisa terkirim dan diterima

```bash
make verify
```

Script ini akan:
- Kirim email test ke Gmail
- Tunggu email sampai
- Terima email test ke mailbox
- Periksa SPF/DKIM/DMARC pass
- Tes open relay (must fail = secure)
- Periksa health (RAM, CPU, disk)

Semua test harus berhasil sebelum go live.

## Make Targets — Daftar Perintah

| Perintah | Kegunaan |
|----------|----------|
| `make help` | Tampilkan daftar ini |
| `make preflight` | Cek persyaratan server (port, RAM, Docker) |
| `make up` | Jalankan mail server (one-time setup) |
| `make plan` | Render dan terapkan config deklaratif |
| `make dns` | Cetak DNS records yang harus dipasang |
| `make verify` | Tes kirim/terima, SPF/DKIM/DMARC, security |
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
│  ├─ apply-plan.sh             # Terapkan dengan stalwart-cli
│  ├─ dns-records.sh            # Print DNS yang harus dipasang
│  ├─ verify.sh                 # Test penuh (kirim, terima, SPF/DKIM/DMARC)
│  └─ lib/env.sh                # Helper load environment
├─ nginx/
│  └─ mail.conf                 # Vhost admin UI + IP allowlist
├─ tests/
│  └─ render.bats               # Unit test render plan
└─ docs/
   ├─ app-integration.md        # Relay transaksional
   ├─ inbound-processing.md     # Webhook / polling IMAP
   ├─ nginx-setup.md            # Setup admin UI
   └─ superpowers/specs/        # Design spec
```

## Troubleshooting

### Port 25 tidak bisa dijangkau dari luar
- Periksa security group/firewall Tencent: pastikan 25 open inbound
- Cek ISP tidak blok port 25 (unlikely tapi mungkin)
- Test dari lain provider: `telnet mail.domain-utama.com 25`

### Email tidak terkirim (stuck di outbound)
- Pastikan `RESEND_API_KEY` valid dan domain sudah verified di Resend
- Cek log: `make logs | grep -i resend`
- Periksa SPF cocok: `make verify`

### DKIM/SPF/DMARC fail
- Tunggu DNS propagate (5-15 menit)
- Cek record di Cloudflare betul dan DNS-only (grey cloud)
- Jalankan `make verify` lagi untuk re-check

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
- Jika masalah permanen, rebuild: `docker-compose down && make up`

## Operasi Sehari-hari

### Monitor kesehatan

```bash
make logs | tail -50      # Lihat 50 baris terakhir
make verify              # Full health check (kirim/terima/SPF/DKIM)
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

Issue? Baca docs di atas dulu, terutama design spec. Kalau masalah di Step 5 (schema reconciliation), lihat output `stalwart-cli describe` dan samakan field names di `plan.json.tpl`.

Kontribusi welcome: fork, buat branch, commit dengan pesan jelas, push, buat pull request.

---

**Terakhir di-update:** 2026-08-15  
**Stalwart version:** v0.16  
**Tested di:** Tencent Cloud Lighthouse (SG/HK/JKT), 2GB RAM, Ubuntu 22.04
