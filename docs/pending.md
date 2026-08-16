# Pending — Sisa Pekerjaan di Server

Repo ini sudah siap dipakai, tapi mail server-nya **belum hidup**. Semua yang tersisa
butuh akses ke VPS dan ke dashboard Cloudflare/Resend, jadi harus dijalankan oleh operator.

**Status terakhir:** 2026-08-16 — kode selesai, 84 test lulus, sudah di-push ke `main`.
Belum pernah dijalankan terhadap server sungguhan.

---

## Ringkasan

| Bagian | Status |
|---|---|
| Repo, skrip, template config, dokumentasi | Selesai |
| Test suite (84 test) | Lulus |
| Review + perbaikan (3 ronde) | Selesai |
| Verifikasi port 25 inbound | **Belum** |
| Task 4 — rekam skema Stalwart v0.16 | **Belum** |
| Deploy dan verifikasi end-to-end | **Belum** |

---

## 1. Gerbang: port 25 inbound

Ini dikerjakan **sebelum** apa pun yang lain. Kalau gagal, seluruh arsitektur berubah dan
tidak ada gunanya melanjutkan langkah di bawahnya.

Buka dulu port 25, 465, 587, 993 di security group Tencent. Lalu:

```bash
# Di server:
sudo nc -l 25

# Dari mesin lain (laptop), ganti <IP_SERVER>:
nc -vz -w 5 <IP_SERVER> 25
```

Harus muncul `succeeded` / `open` di laptop.

**Kalau timeout atau refused setelah security group dibuka:** provider memblokir port 25
masuk. Penerimaan email tidak bisa di-self-host, dan pilihannya berpindah ke Cloudflare
Email Routing atau Resend Inbound yang menerima di MX mereka lalu meneruskan ke server ini.
Itu perubahan desain — hentikan langkah berikutnya dan tinjau ulang spec.

Catatan: port 25 **keluar** memang diblokir Tencent dan itu sudah diperhitungkan. Semua
pengiriman lewat relay Resend. Jangan tertukar antara dua arah ini.

---

## 2. Pasang dependensi

```bash
sudo apt update
sudo apt install -y docker.io docker-compose-plugin gettext-base dnsutils \
                    netcat-openbsd jq python3 swaks

# stalwart-cli — binary terpisah, TIDAK ada di dalam image server
curl --proto '=https' --tlsv1.2 -LsSf \
  https://github.com/stalwartlabs/cli/releases/latest/download/stalwart-cli-installer.sh | sh
```

Docker Compose harus plugin v2 (`docker compose`, dua kata). `scripts/preflight.sh`
memeriksa plugin ini, bukan binary `docker-compose` v1.

---

## 3. Isi `.env`

```bash
cp .env.example .env
nano .env
```

Semua variabel di `REQUIRED_VARS` wajib terisi — termasuk `MAIL_USER_2` dan
`MAIL_USER_2_PASS` untuk mailbox domain kedua. Password admin tidak auto-generate:

```bash
printf 'STALWART_ADMIN_PASS=%s\n' "$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)" >> .env
```

Pastikan tidak ada baris `STALWART_ADMIN_PASS=` kosong yang tersisa di atasnya — yang
terbaca adalah assignment terakhir.

Cloudflare API token dibatasi izin `Zone:DNS:Edit` untuk kedua zona saja.

---

## 4. Preflight dan jalankan container

```bash
make preflight   # perbaiki semua FAIL sebelum lanjut
make up
```

Setelah `make up`, pastikan port admin tidak bocor ke internet — dari laptop:

```bash
nc -vz -w 5 <IP_SERVER> 8080   # harus GAGAL
```

---

## 5. Task 4 — rekam skema Stalwart v0.16 (wajib, belum dikerjakan)

Stalwart v0.16 memindahkan seluruh konfigurasi ke datastore sebagai objek JMAP, dan
skemanya masih baru. Nama field di `config/plan.json.tpl` **provisional** — belum pernah
diadu dengan server sungguhan. Menerapkan plan tanpa langkah ini berisiko gagal diam-diam.

Langkah nol, sebelum yang lain:

```bash
stalwart-cli --help
```

Konfirmasi nama subcommand (`describe`, `query`, `apply`, `snapshot`) dan cara binary ini
menerima kredensial. Kalau nama environment variable-nya bukan
`STALWART_URL` / `STALWART_USER` / `STALWART_PASSWORD`, perbaiki `scripts/lib/cli.sh`.
Ini lebih penting daripada nama field: kalau salah, setiap panggilan `swcli` berjalan
tanpa autentikasi dan tidak ada petunjuk apa pun di command line.

Lalu rekam skemanya:

```bash
source scripts/lib/env.sh && load_env
source scripts/lib/cli.sh

for obj in Domain Account Listener DkimSignature AcmeProvider DnsServer RateLimit SystemSettings; do
  echo "===== $obj ====="
  swcli describe "$obj" --json
done | tee /tmp/schema-dump.txt

swcli snapshot --output /tmp/baseline-snapshot.json
```

Isi tabel di `docs/reference/stalwart-schema.md` dengan nama field sebenarnya, lalu
sesuaikan `config/plan.json.tpl`. **Kalau keluaran server berbeda dari template, keluaran
server yang menang.** Objek relay/queue paling perlu diperiksa — namanya ditulis
`RelayHost` secara provisional.

---

## 6. DNS dan verifikasi domain di Resend

```bash
make dns
```

Tempel semua record ke Cloudflare — **DNS-only (grey cloud)**, proxy oranye merusak mail.
Lalu di dashboard Resend: Domains → Add Domain untuk kedua domain, pasang record DKIM/SPF
yang mereka berikan, klik Verify.

Mengirim lewat relay tanpa verifikasi domain membuat DMARC gagal meski emailnya terkirim.

---

## 7. Terapkan konfigurasi

```bash
make plan
```

Skrip menerapkan plan dua kali untuk membuktikan idempotensi. Kalau apply kedua mengubah
sesuatu, ada operasi yang bukan `upsert` — perbaiki templatenya.

Tunggu sekitar 90 detik lalu pastikan sertifikat ACME terbit:

```bash
docker compose logs --tail=100 | grep -i acme
openssl s_client -connect ${MAIL_HOSTNAME}:465 -servername ${MAIL_HOSTNAME} </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
```

---

## 8. Verifikasi

```bash
make verify
```

**Yang diperiksa:** container hidup, ada yang mendengarkan di port 25, sertifikat TLS cocok,
login IMAP berhasil, relay tanpa auth ditolak, record MX/SPF/DMARC ada di DNS, memori sehat.

**Yang TIDAK diperiksa** — ini harus manual sebelum go-live:

1. Kirim email sungguhan dengan client terautentikasi ke Gmail, buka "Show original",
   pastikan `SPF: PASS`, `DKIM: PASS`, `DMARC: PASS`.
2. Kirim dari Gmail ke `${MAIL_USER_1}` dan `${MAIL_USER_2}`, pastikan sampai di mailbox.
3. Jalankan tes open-relay dari luar (MXToolbox). Probe di `make verify` berjalan dari
   dalam server sendiri, jadi sifatnya indikatif — bukan bukti dari sudut pandang internet.

Catatan NAT: Tencent Lighthouse berada di belakang NAT 1:1 dan hairpin tidak dijamin. Kalau
cek TLS/IMAP gagal padahal server sehat, kemungkinan besar itu jalur probe-nya, bukan
servernya. Konfirmasi dari mesin lain.

---

## 9. Pengerasan setelah berjalan

- Hapus `STALWART_RECOVERY_ADMIN` dari `docker-compose.yml` setelah akun admin normal ada,
  lalu restart container. Selama variabel itu terpasang, ada superadmin permanen yang
  melewati sistem akun, terbaca lewat `docker inspect`, dan tidak tunduk pada auto-ban.
- Pasang vhost nginx untuk admin UI sesuai `docs/nginx-setup.md` — **terbitkan sertifikat
  dulu, baru symlink vhost-nya**, urutan terbalik membuat certbot gagal dan mengunci reload
  nginx untuk semua vhost lain di server itu.
- Naikkan DMARC dari `p=none` ke `quarantine` lalu `reject` setelah dua minggu laporan
  bersih. Laporan dikirim ke `MAIL_ADMIN_EMAIL`.

---

## Di luar scope, kalau nanti dibutuhkan

Backup otomatis (semua state ada di satu bind mount `/opt/mail`, tinggal di-tar), webmail,
antivirus, dan PTR record. Tidak ada yang perlu dibongkar untuk menambahkannya.
