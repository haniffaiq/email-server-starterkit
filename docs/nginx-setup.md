# Konfigurasi Nginx untuk Admin UI Stalwart

Panduan ini menjelaskan cara memasang dan mengonfigurasi nginx untuk melayani admin UI Stalwart dengan pembatasan akses IP.

## Latar Belakang

Admin UI Stalwart mendengarkan pada `127.0.0.1:8080` (localhost saja). Nginx bertindak sebagai reverse proxy dengan SSL termination, membuat admin UI dapat diakses melalui HTTPS dengan pembatasan akses berbasis IP.

## Pemasangan di Server

Jalankan perintah berikut untuk memasang konfigurasi nginx:

```bash
source scripts/lib/env.sh && load_env
sed -e "s/MAIL_HOSTNAME/${MAIL_HOSTNAME}/g" -e "s/ADMIN_ALLOW_IP/${ADMIN_ALLOW_IP}/g" \
  nginx/mail.conf | sudo tee /etc/nginx/sites-available/mail.conf
sudo ln -sf /etc/nginx/sites-available/mail.conf /etc/nginx/sites-enabled/mail.conf
sudo certbot certonly --nginx -d "${MAIL_HOSTNAME}" --non-interactive --agree-tos -m "${MAIL_ADMIN_EMAIL}"
sudo nginx -t && sudo systemctl reload nginx
```

Perintah di atas:
1. Memuat variabel environment dari `scripts/lib/env.sh`
2. Mengganti token `MAIL_HOSTNAME` dan `ADMIN_ALLOW_IP` dalam template `nginx/mail.conf`
3. Menempatkan config ke `/etc/nginx/sites-available/mail.conf`
4. Membuat symbolic link ke `/etc/nginx/sites-enabled/mail.conf`
5. Menggunakan certbot untuk mendapatkan sertifikat SSL dari Let's Encrypt
6. Menguji dan memuat ulang konfigurasi nginx

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

Contoh konfigurasi **BENAR** di docker-compose.yml:
```yaml
services:
  stalwart:
    ports:
      # Admin UI: hanya localhost
      - "127.0.0.1:8080:8080"
      # Port lain untuk mail services
      - "25:25"
      - "143:143"
      - "587:587"
```

Contoh konfigurasi **SALAH**:
```yaml
services:
  stalwart:
    ports:
      # JANGAN LAKUKAN INI:
      - "8080:8080"  # Ini akan publikasikan port ke semua interface
```
