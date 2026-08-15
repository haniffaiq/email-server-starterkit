# Self-Hosted Email Server — Design Spec

**Tanggal:** 2026-08-15
**Status:** Approved (menunggu hasil preflight port 25)

## 1. Tujuan

Menjadikan repo ini sebagai starter yang bisa langsung menjalankan mail server sendiri di
VPS yang menganggur, melayani tiga kebutuhan sekaligus:

1. **Mailbox pribadi/tim** — inbox beneran, dibaca lewat IMAP client.
2. **Relay transaksional** — backend aplikasi mengirim email (reset password, notifikasi)
   lewat SMTP submission dengan kredensial terpisah.
3. **Inbound processing** — email masuk diteruskan ke aplikasi untuk diproses.

Kriteria sukses: dari repo kosong di server baru, tiga perintah (`make preflight`,
`make up`, `make verify`) menghasilkan mail server yang bisa menerima dan mengirim email
dengan SPF, DKIM, dan DMARC lolos, tanpa menjadi open relay.

## 2. Lingkungan Target

| Aspek | Nilai |
|---|---|
| Provider | Tencent Cloud International (SG / HK / Jakarta) |
| Resource | 2 GB RAM, 4 core |
| DNS | Cloudflare |
| Sudah terpasang | Docker + nginx (port 80/443 terpakai) |
| Skala | 2 domain, mailbox sedikit, puluhan email/hari |

**Risiko yang sudah diketahui dan diterima:**

- Tencent Cloud memblokir TCP 25 outbound secara default. Harus dibuka lewat tiket.
  Kalau ditolak, outbound dialihkan ke relay pihak ketiga (lihat §6).
- PTR record hanya bisa diset lewat tiket Tencent, bukan lewat Cloudflare.
- Reputasi IP Tencent tidak sekuat penyedia mail khusus. Email awal berpotensi masuk
  spam di Gmail/Outlook meski autentikasi sudah benar.

## 3. Keputusan Teknis

| Keputusan | Pilihan | Alasan |
|---|---|---|
| Mail stack | **Stalwart Mail Server** | Satu binary Rust berisi SMTP + IMAP + JMAP + spam filter + admin UI. Idle ~350–500 MB, muat nyaman di RAM 2 GB. Mailcow butuh 6 GB (gugur). |
| Storage | RocksDB embedded + blob di filesystem | Tanpa Postgres/Redis terpisah. Hemat RAM, backup cukup satu folder. |
| Webmail | **Tidak ada** | Akses lewat IMAP client saja (Apple Mail, Thunderbird, K-9). Nol RAM tambahan. |
| Deployment | Docker Compose, satu service | Konsisten dengan nginx + Docker yang sudah ada di server. |
| TLS | certbot di host + deploy-hook | Port 80/443 sudah dipegang nginx. Satu sumber sertifikat, tidak rebutan ACME. |
| Anti brute force | Fail2ban bawaan Stalwart | Tidak perlu fail2ban host tambahan. |
| Backup | Di luar scope tahap ini | Semua state ditaruh di satu bind mount supaya mudah ditambahkan nanti. |

## 4. Arsitektur

```
Internet
  ├─ :25        ──────────────► Stalwart   inbound: SPF/DKIM/DMARC check → spam filter → RocksDB
  ├─ :465/:587  ──────────────► Stalwart   submission, WAJIB auth (user pribadi + user app)
  ├─ :993       ──────────────► Stalwart   IMAP TLS untuk mail client
  └─ :443 ─► nginx ─► 127.0.0.1:8080 ─► Stalwart   admin UI saja, tidak terekspos langsung

Outbound: :25 langsung  ──ATAU──  relay eksternal (dipilih lewat .env, tanpa ubah config lain)
```

**Alur inbound:** MX menunjuk ke `mail.<domain>` → Stalwart menerima di :25 → verifikasi
SPF/DKIM/DMARC pengirim → spam filter → simpan ke RocksDB → dibaca client lewat IMAP :993.

**Alur outbound personal:** mail client → :465 (implicit TLS) dengan auth → Stalwart
menandatangani DKIM → kirim ke MX tujuan.

**Alur outbound aplikasi:** backend → :587 (STARTTLS) dengan kredensial user `noreply@`
yang terpisah dan punya rate limit sendiri.

**Alur inbound ke aplikasi:** dua jalur disiapkan, dipilih saat operasional.

1. **Webhook** — Stalwart mengirim HTTP POST ke endpoint aplikasi setiap email diterima.
   Realtime; butuh endpoint yang bisa dijangkau.
2. **Polling IMAP** — aplikasi login ke mailbox khusus (`inbox@`) dan membaca berkala.
   Lebih sederhana, tidak butuh endpoint publik.

**Resource guard:** swap 2 GB dibuat saat bootstrap, container diberi `mem_limit` agar
lonjakan memori tidak memicu OOM killer terhadap proses lain di server.

## 5. Struktur Repo

```
email-server/
├─ .env.example              # MAIL_DOMAIN_1/2, MAIL_HOSTNAME, ADMIN_PASS, RELAY_*
├─ .gitignore                # .env, data/, cert
├─ docker-compose.yml        # satu service, mem_limit, restart: always
├─ config/stalwart.toml.tpl  # template config, dirender dari .env
├─ nginx/mail.conf           # reverse proxy admin UI + IP allowlist
├─ scripts/
│  ├─ preflight.sh           # cek port 25 outbound, PTR, RAM/swap, bentrok port, docker
│  ├─ bootstrap.sh           # buat swap + direktori, render config, compose up, cetak admin pass
│  ├─ dns-records.sh         # cetak semua record untuk ditempel ke Cloudflare, termasuk DKIM
│  ├─ certs-hook.sh          # deploy-hook certbot: salin PEM ke volume + reload container
│  └─ verify.sh              # tes kirim/terima, SPF/DKIM/DMARC, open-relay, blocklist
├─ Makefile                  # preflight / up / dns / verify / logs / backup
└─ README.md
```

Semua state persisten berada di satu bind mount `/opt/mail/` (RocksDB, blob, config
terender, DKIM private key).

**Alur pemakaian:** `make preflight` → perbaiki temuan merah → `make up` → `make dns`
(tempel record ke Cloudflare, ajukan tiket PTR) → `make verify`.

## 6. DNS

Semua record di Cloudflare harus **DNS-only (grey cloud)**. Proxy oranye akan merusak
pengiriman mail.

| Type | Name | Value | Catatan |
|---|---|---|---|
| A | `mail` | IP server | grey cloud wajib |
| MX | `@` | `mail.<domain>` prio 10 | dipasang untuk kedua domain |
| TXT | `@` | `v=spf1 mx -all` | jika pakai relay: `v=spf1 mx include:<relay> -all` |
| TXT | `<selector>._domainkey` | public key dari Stalwart | digenerate saat bootstrap, per domain |
| TXT | `_dmarc` | `v=DMARC1; p=none; rua=mailto:dmarc@<domain>` | naikkan ke `quarantine`/`reject` setelah 2 minggu laporan bersih |
| PTR | — | `mail.<domain>` | lewat tiket Tencent, bukan Cloudflare |

MTA-STS dan TLS-RPT bersifat opsional; `make dns` tetap mencetaknya karena menambah
kepercayaan di Gmail dan Outlook.

**Fallback relay:** jika port 25 outbound tidak dibuka Tencent, isi variabel `RELAY_HOST`,
`RELAY_USER`, `RELAY_PASS` di `.env` lalu restart. Outbound berpindah ke relay tanpa
mengubah konfigurasi lain. SPF harus ditambahi `include:` milik relay tersebut.

## 7. Keamanan

- **Bukan open relay.** Port 25 hanya menerima email untuk domain sendiri. Submission di
  465/587 selalu mewajibkan autentikasi. `verify.sh` menjalankan tes open-relay eksplisit
  setiap kali dipanggil, bukan mengandalkan asumsi default aman.
- **Admin UI tidak terbuka bebas.** Diakses lewat nginx dengan IP allowlist, tidak pernah
  memublikasikan port 8080 ke internet.
- **Kredensial.** Password admin digenerate acak saat bootstrap dan disimpan di `.env`
  yang masuk `.gitignore`. Tidak ada kredensial yang di-commit.
- **Pemisahan user.** User aplikasi (`noreply@`) terpisah dari mailbox pribadi dan punya
  rate limit sendiri, sehingga kebocoran kredensial aplikasi tidak membuka mailbox pribadi
  dan blast-nya terpotong.
- **Firewall.** Security group Tencent hanya membuka 25, 465, 587, 993, 80, 443.
- **Brute force.** Auto-ban bawaan Stalwart aktif untuk percobaan login gagal berulang.

## 8. Verifikasi

`make verify` memeriksa dan melaporkan lulus/gagal untuk:

- Port 25 inbound dapat dijangkau dari luar, dan outbound dapat menjangkau MX publik
- Sertifikat TLS valid dan cocok dengan `mail.<domain>`
- Email uji ke Gmail terkirim, beserta status inbox atau spam
- SPF, DKIM, dan DMARC lolos serta selaras (aligned)
- Tes open-relay memberi hasil negatif
- IP tidak terdaftar di blocklist utama
- RAM dan swap dalam batas sehat

## 9. Di Luar Scope

Webmail, backup otomatis, antivirus (ClamAV), high availability, dan multi-server. Semua
ditunda; struktur satu bind mount dan profil compose menyisakan ruang untuk menambahkannya
tanpa membongkar konfigurasi.

## 10. Pertanyaan Terbuka

- Hasil tes port 25 outbound di server belum masuk. Menentukan apakah outbound langsung
  atau lewat relay. Desain menangani keduanya lewat `.env`, jadi tidak memblokir
  implementasi.
- Nama kedua domain belum ditentukan; diisi lewat `.env` saat deploy.
