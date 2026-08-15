# Pengaturan Email Client

Ikuti panduan di bawah untuk mengatur email client Anda agar terhubung ke mail server ini.

## Pengaturan Server

| Protokol | Host | Port | Keamanan | Username | Password |
|---|---|---|---|---|---|
| IMAP | `${MAIL_HOSTNAME}` | 993 | SSL/TLS | Alamat email lengkap | Password akun Anda |
| SMTP (submission) | `${MAIL_HOSTNAME}` | 465 | SSL/TLS | Alamat email lengkap | Password akun Anda |

### Catatan Port 587

Port 587 juga tersedia sebagai alternatif untuk client yang tidak mendukung SSL/TLS implisit (Implicit TLS). Gunakan STARTTLS untuk koneksi di port ini.

| Protokol | Host | Port | Keamanan | Username | Password |
|---|---|---|---|---|---|
| SMTP (alternative) | `${MAIL_HOSTNAME}` | 587 | STARTTLS | Alamat email lengkap | Password akun Anda |

---

## Apple Mail (macOS & iOS)

### macOS

1. Buka **Mail** → pilih **Mail** menu → **Settings** (atau **Preferences** di macOS yang lebih lama)
2. Klik tab **Accounts** dan tombol **+** untuk menambah akun
3. Pilih **Other Mail Account** (Akun Email Lain)
4. Masukkan:
   - **Email Address**: Alamat email lengkap Anda
   - **Password**: Password akun Anda
5. Klik **Continue**
6. Jika diminta konfigurasi manual:
   - **Incoming Mail Server (IMAP)**:
     - Server: `${MAIL_HOSTNAME}`
     - Port: 993
     - Username: Alamat email lengkap
     - Password: Password akun Anda
     - Use SSL: ✓
   - **Outgoing Mail Server (SMTP)**:
     - Server: `${MAIL_HOSTNAME}`
     - Port: 465
     - Username: Alamat email lengkap
     - Password: Password akun Anda
     - Use SSL: ✓
7. Klik **Sign In** untuk menyelesaikan

### iOS/iPadOS

1. Buka **Settings** → **Mail** → **Accounts** → **Add Account**
2. Pilih **Other**
3. Masukkan:
   - **Name**: Nama Anda (untuk ditampilkan di header email)
   - **Email**: Alamat email lengkap Anda
   - **Password**: Password akun Anda
4. Tap **Next**
5. Pilih **IMAP** untuk incoming
6. Atur:
   - **Host Name**: `${MAIL_HOSTNAME}`
   - **User Name**: Alamat email lengkap
   - **Password**: Password akun Anda
7. Tap **Next**
8. Pilih **SMTP** untuk outgoing
9. Atur:
   - **Host Name**: `${MAIL_HOSTNAME}`
   - **User Name**: Alamat email lengkap
   - **Password**: Password akun Anda
10. Tap **Next** kemudian **Done**

---

## Mozilla Thunderbird

1. Buka Thunderbird dan klik **Create a new account** atau **File** → **New** → **Email Account**
2. Masukkan:
   - **Your name**: Nama Anda
   - **Email address**: Alamat email lengkap Anda
   - **Password**: Password akun Anda
3. Klik **Continue**
4. Jika Thunderbird tidak dapat mendeteksi pengaturan otomatis:
   - Klik **Manual config**
   - Atur **Incoming (IMAP)**:
     - Server: `${MAIL_HOSTNAME}`
     - Port: 993
     - Connection security: SSL/TLS
     - Authentication: Normal password
     - Username: Alamat email lengkap
   - Atur **Outgoing (SMTP)**:
     - Server: `${MAIL_HOSTNAME}`
     - Port: 465
     - Connection security: SSL/TLS
     - Authentication: Normal password
     - Username: Alamat email lengkap
5. Klik **Done** untuk menyelesaikan

---

## Android

Langkah-langkah umum untuk aplikasi email standar Android (seperti Gmail, Samsung Mail, atau AOSP Mail):

1. Buka aplikasi email pilihan Anda
2. Tap **Add Account** atau ikon **+**
3. Pilih **IMAP** atau **Other/Manual**
4. Masukkan:
   - **Email address**: Alamat email lengkap Anda
   - **Password**: Password akun Anda
5. Atur server IMAP:
   - **Host**: `${MAIL_HOSTNAME}`
   - **Port**: 993
   - **Security**: SSL/TLS
   - **Username**: Alamat email lengkap
6. Atur server SMTP:
   - **Host**: `${MAIL_HOSTNAME}`
   - **Port**: 465
   - **Security**: SSL/TLS
   - **Username**: Alamat email lengkap
7. Tap **Next** atau **Done** untuk menyelesaikan

---

## Troubleshooting

- **Connection refused**: Pastikan server berjalan (`make up`) dan firewall tidak memblokir port 993 (IMAP) atau 465 (SMTP)
- **Certificate error**: Pastikan hostname di client sesuai dengan `${MAIL_HOSTNAME}` di `.env`
- **Login failed**: Pastikan username adalah **alamat email lengkap**, bukan hanya bagian sebelum @
- **Port 465 tidak bekerja?** Gunakan port 587 dengan STARTTLS sebagai alternatif
