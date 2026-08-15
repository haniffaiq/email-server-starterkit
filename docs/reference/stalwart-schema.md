# Referensi Schema Stalwart — Catatan Wajib Sebelum `make plan`

Dokumen ini adalah **stub kerja**, bukan referensi lengkap yang sudah final. Isinya harus dilengkapi oleh operator dengan data dari server yang sebenarnya sebelum `make plan` pertama kali dijalankan.

## Kenapa dokumen ini perlu ada

Stalwart v0.16 memindahkan **seluruh konfigurasi** ke datastore sebagai objek JMAP (`Domain`, `Account`, `Listener`, `DkimSignature`, dst) — tidak ada lagi file TOML/YAML statis yang bisa dibaca langsung untuk tahu nama field yang benar. Template `config/plan.json.tpl` di repo ini memakai nama object dan field yang **provisional**: diambil dari dokumen perencanaan (task briefs) saat repo ini dibuat, bukan hasil verifikasi terhadap server Stalwart v0.16 yang sungguhan.

Artinya nama field di `plan.json.tpl` **bisa saja salah**. Kalau Anda menjalankan `make plan` tanpa mengecek dulu, kemungkinan besar akan gagal dengan error validasi schema, atau — lebih buruk — berhasil apply tapi ke field yang salah.

**Aturan yang berlaku: kalau output live `swcli describe` berbeda dari yang ada di `plan.json.tpl`, output live yang benar. Perbaiki template, bukan sebaliknya.**

## Langkah yang harus dilakukan (sekali per server baru)

Ini dilakukan **setelah** `make up` (server sudah jalan) tapi **sebelum** `make plan` pertama kali.

1. Pastikan `stalwart-cli` sudah terpasang di host (lihat prerequisites di README) dan `STALWART_ADMIN_PASS` sudah terisi di `.env`.
2. Muat wrapper `swcli` supaya tidak perlu mengetik `--url` dan kredensial berulang-ulang:

   ```bash
   source scripts/lib/cli.sh
   ```

   `swcli` adalah host binary `stalwart-cli` yang sudah dibungkus dengan `--url http://127.0.0.1:8080 --user admin --password "$STALWART_ADMIN_PASS"` (lihat `scripts/lib/cli.sh`). Ini satu-satunya mekanisme yang dipakai seluruh script di repo ini untuk bicara ke Stalwart — **bukan** `docker exec stalwart stalwart-cli ...`. Image server (`stalwartlabs/stalwart`) dan CLI (`stalwart-cli`) adalah dua artifact terpisah; CLI tidak ada di dalam image server.

3. Jalankan `describe` untuk setiap object type yang dipakai `plan.json.tpl`, plus object relay/queue:

   ```bash
   swcli describe Domain --json         > /tmp/schema-domain.json
   swcli describe Account --json        > /tmp/schema-account.json
   swcli describe Listener --json       > /tmp/schema-listener.json
   swcli describe DkimSignature --json  > /tmp/schema-dkim.json
   swcli describe AcmeProvider --json   > /tmp/schema-acme.json
   swcli describe DnsServer --json      > /tmp/schema-dnsserver.json
   swcli describe RateLimit --json      > /tmp/schema-ratelimit.json
   swcli describe SystemSettings --json > /tmp/schema-systemsettings.json
   # Object relay/queue: nama pastinya bisa berbeda per versi/build — cek
   # daftar object yang tersedia dulu (`swcli describe --list` atau setara),
   # lalu describe object yang menangani outbound relay host / mail queue.
   swcli describe <RelayOrQueueObject> --json > /tmp/schema-relay.json
   ```

4. Ambil snapshot baseline datastore sebelum apply pertama — berguna sebagai pembanding dan untuk rollback manual kalau `make plan` merusak sesuatu:

   ```bash
   swcli snapshot --output baseline.json
   ```

5. Bandingkan setiap file `/tmp/schema-*.json` dengan field yang dipakai di `config/plan.json.tpl`. Isi tabel di bawah dengan nama field/object yang **benar** (hasil live), lalu perbaiki `plan.json.tpl` supaya cocok.

## Tabel isian — object vs field

Isi kolom "Field/nama live (hasil `swcli describe`)" dan "Cocok dengan template?" untuk tiap baris setelah menjalankan langkah di atas. Kolom "Field di `plan.json.tpl` (provisional)" sudah diisi sesuai state template saat ini, hanya sebagai titik awal perbandingan.

| Object Stalwart | Dipakai untuk | Field di `plan.json.tpl` (provisional) | Field/nama live (hasil `swcli describe`) | Cocok dengan template? |
|---|---|---|---|---|
| `Domain` | Domain mail dan default domain | `name`, `certificateManagement`, `acmeProviderId`, `dnsServerId`, `origin` | _(isi setelah describe)_ | _(Y/N)_ |
| `Account` | Mailbox pribadi + akun aplikasi | `@type`, `name`, `description`, `secrets`, `emails` | _(isi setelah describe)_ | _(Y/N)_ |
| `Listener` | Port SMTP/Submission/IMAP/HTTP | `name`, `protocol`, `bindAddress`, `port`, `tls` | _(isi setelah describe)_ | _(Y/N)_ |
| `DkimSignature` | Key DKIM per domain | `domainId`, `selector`, `algorithm` | _(isi setelah describe)_ | _(Y/N)_ |
| `AcmeProvider` | Let's Encrypt via DNS-01 | `name`, `directory`, `challengeType`, `contact`, `renewBefore` | _(isi setelah describe)_ | _(Y/N)_ |
| `DnsServer` | Kredensial provider DNS (Cloudflare) | `name`, `@type`, `apiToken` | _(isi setelah describe)_ | _(Y/N)_ |
| `RateLimit` | Rate limit akun aplikasi | `name`, `accountId`, `messages`, `period` | _(isi setelah describe)_ | _(Y/N)_ |
| `SystemSettings` | Default domain, default relay host | `defaultDomainId`, `defaultRelayHostId` | _(isi setelah describe)_ | _(Y/N)_ |
| Relay/queue (nama object belum dikonfirmasi — template memakai `RelayHost`) | Relay outbound ke Resend | `name`, `host`, `port`, `tls`, `authUsername`, `authSecret` | _(isi setelah describe — cek apakah `RelayHost` benar-benar ada di build ini)_ | _(Y/N)_ |

## Setelah tabel terisi

- Update `config/plan.json.tpl` supaya setiap nama object/field sama persis dengan kolom "Field/nama live" di tabel ini.
- Simpan hasil `swcli describe` (`/tmp/schema-*.json`) dan `baseline.json` di tempat yang tidak ikut ke-commit (misalnya di luar repo, atau di `.gitignore`) — isinya bisa memuat detail internal server.
- Baru setelah ini `make plan` aman dijalankan. Kalau masih gagal validasi, ulangi describe untuk object yang errornya spesifik, bukan menebak-nebak dari dokumentasi upstream.

Langkah ini hanya perlu dilakukan sekali untuk server baru — schema tidak berubah lagi setelah dicatat, kecuali ada upgrade Stalwart mayor berikutnya (di luar v0.16), yang berarti proses ini perlu diulang.
