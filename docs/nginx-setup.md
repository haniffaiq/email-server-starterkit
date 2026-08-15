# Konfigurasi Nginx untuk Admin UI Stalwart

Panduan ini menjelaskan cara memasang dan mengonfigurasi nginx untuk melayani admin UI Stalwart dengan pembatasan akses IP.

## Latar Belakang

Admin UI Stalwart mendengarkan pada `127.0.0.1:8080` (localhost saja). Nginx bertindak sebagai reverse proxy dengan SSL termination, membuat admin UI dapat diakses melalui HTTPS dengan pembatasan akses berbasis IP.

## Pemasangan di Server

Urutan di bawah ini penting. Vhost `mail.conf` memuat baris `ssl_certificate` yang menunjuk ke
sertifikat Let's Encrypt untuk `MAIL_HOSTNAME`. Jika vhost ini dipasang ke `sites-enabled`
**sebelum** sertifikat tersebut ada, `nginx -t` akan gagal karena file sertifikat belum ada —
dan karena `certbot --nginx` melakukan reload nginx sebagai bagian dari prosesnya, kegagalan itu
akan membuat certbot berhenti di tengah jalan sambil meninggalkan vhost yang rusak tetap
ter-enable, yang kemudian memblokir reload nginx untuk vhost lain di server yang sama. Karena
itu, sertifikat harus diterbitkan **sebelum** vhost ini dipasang.

Vhost `mail.conf` juga tidak memiliki blok `listen 80`, jadi ia tidak bisa dijadikan target
langsung oleh `certbot --nginx` untuk validasi HTTP-01. Terbitkan sertifikat lebih dulu lewat
vhost default yang sudah ada di server (certbot akan menempel ke server default tersebut), atau
gunakan `--webroot` jika servernya belum punya vhost default.

Jalankan perintah berikut secara berurutan:

```bash
source scripts/lib/env.sh && load_env

# 1. Terbitkan sertifikat SSL LEBIH DULU, sebelum vhost mail.conf dipasang.
#    Ini menempel ke vhost default (port 80) yang sudah ada di server;
#    gunakan --webroot -w /path/ke/webroot sebagai gantinya jika belum ada vhost default.
sudo certbot certonly --nginx -d "${MAIL_HOSTNAME}" --non-interactive --agree-tos -m "${MAIL_ADMIN_EMAIL}"

# 2. Baru setelah sertifikat ada, pasang vhost admin UI.
sed -e "s/MAIL_HOSTNAME/${MAIL_HOSTNAME}/g" -e "s/ADMIN_ALLOW_IP/${ADMIN_ALLOW_IP}/g" \
  nginx/mail.conf | sudo tee /etc/nginx/sites-available/mail.conf
sudo ln -sf /etc/nginx/sites-available/mail.conf /etc/nginx/sites-enabled/mail.conf

# 3. Uji konfigurasi sebelum reload — jangan pernah reload tanpa nginx -t lulus dulu.
sudo nginx -t && sudo systemctl reload nginx
```

Perintah di atas:
1. Memuat variabel environment dari `scripts/lib/env.sh`
2. Menggunakan certbot untuk mendapatkan sertifikat SSL dari Let's Encrypt **sebelum** vhost
   dipasang, sehingga `ssl_certificate` pada `mail.conf` sudah menunjuk ke file yang benar-benar ada
3. Mengganti token `MAIL_HOSTNAME` dan `ADMIN_ALLOW_IP` dalam template `nginx/mail.conf`
4. Menempatkan config ke `/etc/nginx/sites-available/mail.conf`
5. Membuat symbolic link ke `/etc/nginx/sites-enabled/mail.conf`
6. Menguji konfigurasi dengan `nginx -t` dan memuat ulang nginx hanya jika pengujian lulus

### ADMIN_ALLOW_IP hanya menerima SATU alamat

Token `ADMIN_ALLOW_IP` di `mail.conf` dirender menjadi satu baris `allow ADMIN_ALLOW_IP;`.
Nginx menolak baris `allow` yang berisi lebih dari satu alamat (`allow 1.2.3.4 5.6.7.8;` adalah
error "invalid number of arguments"). Karena itu, `ADMIN_ALLOW_IP` di `.env` harus diisi dengan
**tepat satu** alamat IP atau CIDR (misalnya `203.0.113.45` atau `203.0.113.0/24`), bukan daftar
yang dipisah spasi.

Jika Anda perlu mengizinkan lebih dari satu alamat — misalnya IP rumah yang berubah-ubah
(dynamic IP) ditambah IP kantor — isi `ADMIN_ALLOW_IP` dengan salah satu alamat saat instalasi
awal, lalu tambahkan alamat-alamat tambahan sebagai baris `allow <ip>;` tambahan secara manual
mengikuti prosedur "Menambah IP Baru ke Allowlist" di bawah ini. Untuk IP rumah yang sering
berganti, pertimbangkan menggunakan rentang CIDR yang mencakup rentang IP dinamis dari ISP Anda,
atau perbarui baris `allow` tersebut setiap kali IP berubah.

## Menambah IP Baru ke Allowlist

Untuk menambahkan IP baru ke dalam daftar yang diizinkan:

1. Edit file `/etc/nginx/sites-available/mail.conf`:

```bash
sudo nano /etc/nginx/sites-available/mail.conf
```

2. Temukan baris dengan `deny all;` dan tambahkan baris `allow <ip>;` sebelumnya. Contoh:

```nginx
# Admin surface is never open to the internet at large.
allow 192.168.1.100;
allow 203.0.113.45;
deny all;
```

3. Uji dan muat ulang konfigurasi:

```bash
sudo nginx -t && sudo systemctl reload nginx
```

## Catatan Penting tentang Sertifikat

Sertifikat nginx ini **terpisah sepenuhnya** dari sertifikat Stalwart:
- **Stalwart**: Mengelola sertifikatnya sendiri melalui ACME DNS-01 via Cloudflare
- **Nginx**: Menggunakan certbot dan Let's Encrypt seperti vhost lain di server

Tidak ada file sertifikat yang dibagikan antara keduanya, sehingga proses renewal satu tidak akan mengganggu yang lain.

## Peringatan: Jangan Publikasikan Port 8080

Port 8080 tempat Stalwart mendengarkan **harus tetap terbatas pada localhost saja**. Jangan pernah publikasikan port ini di `docker-compose.yml` atau konfigurasi jaringan lainnya. Admin UI hanya boleh diakses melalui nginx dengan pembatasan IP yang telah dikonfigurasi.

Contoh konfigurasi **BENAR** di docker-compose.yml (sesuai `docker-compose.yml` yang sebenarnya
dipakai deployment ini — 25/465/587/993 publik, 8080 hanya di localhost; port 143 IMAP plaintext
sengaja tidak dibuka karena deployment ini tidak mengaktifkan listener-nya):
```yaml
services:
  stalwart:
    ports:
      # Admin UI: hanya localhost
      - "127.0.0.1:8080:8080"
      # Port lain untuk mail services
      - "25:25"     # SMTP
      - "465:465"   # SMTPS (submissions)
      - "587:587"   # SMTP submission (STARTTLS)
      - "993:993"   # IMAPS
```

Contoh konfigurasi **SALAH**:
```yaml
services:
  stalwart:
    ports:
      # JANGAN LAKUKAN INI:
      - "8080:8080"  # Ini akan publikasikan port ke semua interface
```
