# Self-Hosted Email Server — Design Spec

**Tanggal:** 2026-08-15
**Status:** Approved
**Revisi:** rev2 — Stalwart v0.16 (config deklaratif), relay Resend sebagai jalur outbound utama,
ACME DNS-01 Cloudflare menggantikan certbot.

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
| Provider | Tencent Cloud Lighthouse, region International (SG / HK / JKT) |
| Resource | 2 GB RAM, 2 core |
| DNS | Cloudflare (punya API token untuk zona terkait) |
| Sudah terpasang | Docker + nginx (port 80/443 terpakai) |
| Skala | 2 domain, mailbox sedikit, puluhan email/hari |

**Kondisi yang sudah dipastikan:**

- **TCP 25 outbound diblokir Tencent Lighthouse.** Ini standar anti-spam provider dan
  tiket unblock jarang dikabulkan untuk Lighthouse. Konsekuensi: seluruh pengiriman keluar
  lewat relay (§6), bukan koneksi langsung ke MX tujuan.
- **TCP 25 inbound belum diverifikasi.** Yang diblokir provider umumnya hanya arah keluar,
  tapi ini menentukan apakah penerimaan email bisa di-self-host sama sekali. Diverifikasi
  di task pertama implementasi (§9), sebelum ada komponen lain dibangun.
- PTR record tidak relevan lagi untuk pengiriman karena outbound lewat relay, tapi tetap
  diset ke `mail.<domain>` lewat tiket Tencent agar konsisten.

## 3. Keputusan Teknis

| Keputusan | Pilihan | Alasan |
|---|---|---|
| Mail stack | **Stalwart Mail Server v0.16** | Satu binary Rust berisi SMTP + IMAP + JMAP + spam filter + admin UI. Idle ~350–500 MB, muat nyaman di RAM 2 GB. Mailcow butuh 6 GB (gugur). |
| Image | `stalwartlabs/stalwart:v0.16` | Tag minor dipin, bukan `latest`, agar upgrade tidak terjadi diam-diam saat restart. |
| Konfigurasi | **Deklaratif via `stalwart-cli apply`** | v0.16 memindahkan seluruh setting ke datastore; `config.json` di disk hanya menunjuk datastore. Plan JSON idempoten (`upsert`) di-commit ke repo, jadi seluruh konfigurasi jadi kode. |
| Storage | RocksDB embedded | Tanpa Postgres/Redis terpisah. Hemat RAM, backup cukup satu folder. |
| TLS mail | **ACME DNS-01 via Cloudflare, di dalam Stalwart** | Tidak butuh port 80/443 yang sudah dipegang nginx, tidak butuh certbot maupun deploy-hook, dan renew otomatis. Sertifikat untuk :25/:465/:993 dikelola Stalwart sendiri. |
| TLS admin UI | nginx yang sudah ada | Stalwart HTTP bind ke `127.0.0.1:8080`, nginx terminasi TLS di vhost terpisah dengan sertifikatnya sendiri. Dua sertifikat independen, tidak ada file yang dipakai bersama. |
| Outbound | **Relay Resend** (`smtp.resend.com`) | Port 25 outbound mati. Free tier 3.000/bulan, verifikasi domain + DKIM tersedia. |
| Webmail | Tidak ada | Akses lewat IMAP client saja. Nol RAM tambahan. |
| Anti brute force | Auto-ban bawaan Stalwart | Tidak perlu fail2ban host tambahan. |
| Backup | Di luar scope tahap ini | Semua state di satu bind mount agar mudah ditambahkan nanti. |

## 4. Arsitektur

```
Internet
  ├─ :25        ──────────────► Stalwart   inbound: SPF/DKIM/DMARC check → spam filter → RocksDB
  ├─ :465/:587  ──────────────► Stalwart   submission, WAJIB auth (user pribadi + user app)
  ├─ :993       ──────────────► Stalwart   IMAP TLS untuk mail client
  └─ :443 ─► nginx ─► 127.0.0.1:8080 ─► Stalwart   admin UI saja, tidak terekspos langsung

Outbound: Stalwart ──► smtp.resend.com:465 (auth) ──► MX tujuan
          (port 25 keluar diblokir provider, jadi tidak pernah dipakai)

TLS mail: Stalwart ──► ACME DNS-01 ──► Cloudflare API ──► Let's Encrypt
```

**Alur inbound:** MX menunjuk ke `mail.<domain>` → Stalwart menerima di :25 → verifikasi
SPF/DKIM/DMARC pengirim → spam filter → simpan ke RocksDB → dibaca client lewat IMAP :993.

**Alur outbound personal:** mail client → :465 (implicit TLS) dengan auth → Stalwart
menandatangani DKIM domain sendiri → serahkan ke Resend → Resend kirim ke MX tujuan.

**Alur outbound aplikasi:** backend → :587 (STARTTLS) dengan kredensial user `noreply@`
yang terpisah dan punya rate limit sendiri → jalur yang sama.

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
├─ .env.example              # MAIL_DOMAIN_1/2, MAIL_HOSTNAME, CF_API_TOKEN, RESEND_API_KEY, ...
├─ .gitignore                # .env, data/, plan yang sudah dirender
├─ docker-compose.yml        # satu service, mem_limit, restart: always, bind mount
├─ config/config.json        # DataStore RocksDB — satu-satunya config di disk
├─ config/plan.json.tpl      # plan deklaratif: Domain, Account, Listener, AcmeProvider,
│                            # DnsServer (Cloudflare), relay Resend, DkimSignature, rate limit
├─ nginx/mail.conf           # vhost admin UI + IP allowlist
├─ scripts/
│  ├─ preflight.sh           # cek inbound 25, outbound 25, RAM/swap, bentrok port, docker
│  ├─ bootstrap.sh           # swap + direktori (UID 2000), up, recovery admin, apply plan
│  ├─ render-plan.sh         # render plan.json.tpl dari .env
│  ├─ dns-records.sh         # cetak record Cloudflare + record verifikasi domain Resend
│  └─ verify.sh              # tes kirim/terima, SPF/DKIM/DMARC, open-relay, blocklist
├─ tests/                    # bats: uji render template & parsing skrip di laptop
├─ Makefile                  # preflight / up / plan / dns / verify / logs
└─ README.md
```

Seluruh state persisten berada di satu bind mount `/opt/mail/` (RocksDB, blob, config,
DKIM private key), dimiliki UID 2000 sesuai persyaratan image Stalwart.

**Alur pemakaian:** `make preflight` → perbaiki temuan merah → `make up` → `make dns`
(tempel record ke Cloudflare, verifikasi domain di Resend) → `make plan` → `make verify`.

## 6. DNS dan Relay

Semua record di Cloudflare harus **DNS-only (grey cloud)**. Proxy oranye akan merusak
pengiriman mail.

| Type | Name | Value | Catatan |
|---|---|---|---|
| A | `mail` | IP server | grey cloud wajib |
| MX | `@` | `mail.<domain>` prio 10 | dipasang untuk kedua domain |
| TXT | `@` | `v=spf1 include:_spf.resend.com -all` | outbound lewat Resend; `mx` tidak disertakan karena server tidak pernah mengirim langsung |
| TXT | `<selector>._domainkey` | public key DKIM | dari Resend (untuk mail yang dikirim keluar) dan dari Stalwart (untuk penandatanganan lokal) |
| TXT | `_dmarc` | `v=DMARC1; p=none; rua=mailto:dmarc@<domain>` | naikkan ke `quarantine`/`reject` setelah 2 minggu laporan bersih |

Nilai persis SPF dan DKIM diambil dari halaman verifikasi domain Resend saat implementasi;
`make dns` mencetak gabungan record Stalwart dan Resend dalam satu daftar.

**Kredensial relay:** host `smtp.resend.com`, port 465 implicit TLS, username `resend`,
password berupa API key. API key disimpan di `.env` (tidak di-commit) dan masuk ke plan
saat render.

**Deliverability:** relay memakai IP mereka, tapi DMARC tetap menuntut alignment. Karena
itu domain wajib diverifikasi di Resend dan DKIM-nya dipasang — mengirim lewat relay tanpa
verifikasi domain membuat DMARC gagal meski email terkirim.

## 7. Keamanan

- **Bukan open relay.** Port 25 hanya menerima email untuk domain sendiri. Submission di
  465/587 selalu mewajibkan autentikasi. `verify.sh` menjalankan tes open-relay eksplisit
  setiap kali dipanggil, bukan mengandalkan asumsi default aman.
- **Admin UI tidak terbuka bebas.** Stalwart HTTP bind ke `127.0.0.1:8080` saja; akses
  lewat nginx dengan IP allowlist. Port 8080 tidak pernah dipublikasikan ke internet.
- **Kredensial.** Cloudflare API token dibatasi ke izin `Zone:DNS:Edit` pada zona terkait
  saja. Resend API key dan password admin disimpan di `.env` yang masuk `.gitignore`.
  Plan yang sudah dirender berisi rahasia sehingga juga tidak di-commit; yang di-commit
  hanya `plan.json.tpl`.
- **Pemisahan user.** User aplikasi (`noreply@`) terpisah dari mailbox pribadi dan punya
  rate limit sendiri, sehingga kebocoran kredensial aplikasi tidak membuka mailbox pribadi
  dan blast-nya terpotong.
- **Firewall.** Security group Tencent hanya membuka 25, 465, 587, 993, 80, 443.
- **Brute force.** Auto-ban bawaan Stalwart aktif untuk percobaan login gagal berulang.

## 8. Verifikasi

`make verify` memeriksa dan melaporkan lulus/gagal untuk:

- Port 25 inbound dapat dijangkau dari luar
- Sertifikat TLS valid dan cocok dengan `mail.<domain>` di :465 dan :993
- Email uji ke Gmail terkirim lewat relay, beserta status inbox atau spam
- SPF, DKIM, dan DMARC lolos serta selaras (aligned)
- Email uji dari luar masuk ke mailbox dan terbaca lewat IMAP
- Tes open-relay memberi hasil negatif
- RAM dan swap dalam batas sehat

## 9. Urutan Implementasi dan Titik Gagal

Task pertama adalah verifikasi konektivitas port 25 inbound. Kalau inbound ikut diblokir,
penerimaan email tidak bisa di-self-host dan arsitekturnya berubah total (harus pakai
layanan inbound pihak ketiga yang mem-forward ke server). Ini diuji sebelum ada komponen
lain dibangun agar kegagalan ketahuan di menit pertama, bukan setelah semuanya jadi.

## 10. Di Luar Scope

Webmail, backup otomatis, antivirus (ClamAV), high availability, multi-server, dan
pengaturan PTR. Struktur satu bind mount menyisakan ruang untuk menambahkannya tanpa
membongkar konfigurasi.
