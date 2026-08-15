# Integrasi Aplikasi — Pengiriman Email Transaksional

Panduan ini menjelaskan cara menghubungkan backend aplikasi Anda ke mail server ini untuk mengirim email transaksional (notifikasi, konfirmasi, reset password, dll).

## Ikhtisar

Email transaksional dikirim melalui akun terpisah (`MAIL_APP_USER`) yang:
- **Tidak dapat membaca mailbox pribadi** — kredensial bocor tidak membuka inbox pengguna
- **Memiliki rate limit sendiri** — dibatasi 200 pesan per jam untuk mencegah blast jika kredensial dikompromis
- **Menggunakan SMTP submission** — port 465 (implicit TLS) atau 587 (STARTTLS) dengan autentikasi

## Konfigurasi

Sebelum aplikasi dapat terhubung, pastikan akun aplikasi sudah dikonfigurasi:

1. Periksa `.env` Anda berisi:
   ```bash
   MAIL_APP_USER=noreply@domain-utama.com
   MAIL_APP_PASS=password-kuat-yang-aman
   ```

2. Jalankan konfigurasi jika belum:
   ```bash
   make plan
   ```

## Detail Koneksi

| Parameter | Nilai |
|-----------|-------|
| **Host** | `${MAIL_HOSTNAME}` (dari .env, contoh: `mail.domain-utama.com`) |
| **Port** | 465 (implicit TLS) atau 587 (STARTTLS) |
| **Username** | `${MAIL_APP_USER}` (full email address) |
| **Password** | `${MAIL_APP_PASS}` |
| **Enkripsi** | 465 = implicit TLS; 587 = STARTTLS |
| **Rate Limit** | 200 pesan/jam |

## Contoh Pengiriman — Node.js dengan Nodemailer

```javascript
const nodemailer = require('nodemailer');

const transporter = nodemailer.createTransport({
  host: process.env.MAIL_HOSTNAME,        // mail.domain-utama.com
  port: 465,
  secure: true,                            // use implicit TLS
  auth: {
    user: process.env.MAIL_APP_USER,      // noreply@domain-utama.com
    pass: process.env.MAIL_APP_PASS
  }
});

// Send a transaction email
transporter.sendMail({
  from: process.env.MAIL_APP_USER,
  to: 'user@example.com',
  subject: 'Konfirmasi Email Anda',
  html: '<p>Silakan klik <a href="...">di sini</a> untuk mengkonfirmasi email Anda.</p>'
}, (err, info) => {
  if (err) {
    console.error('Gagal mengirim:', err);
  } else {
    console.log('Email terkirim:', info.response);
  }
});
```

## Contoh Pengiriman — Python dengan smtplib

```python
import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
import os

# Konfigurasi dari environment
mail_host = os.getenv('MAIL_HOSTNAME')       # mail.domain-utama.com
mail_port = 465  # atau 587 untuk STARTTLS
mail_user = os.getenv('MAIL_APP_USER')       # noreply@domain-utama.com
mail_pass = os.getenv('MAIL_APP_PASS')

def send_email(to_address, subject, html_body):
    """Send a transactional email."""
    try:
        # Koneksi dengan implicit TLS (port 465)
        server = smtplib.SMTP_SSL(mail_host, mail_port, timeout=10)
        server.login(mail_user, mail_pass)
        
        # Buat pesan
        msg = MIMEMultipart('alternative')
        msg['Subject'] = subject
        msg['From'] = mail_user
        msg['To'] = to_address
        msg.attach(MIMEText(html_body, 'html'))
        
        # Kirim
        server.sendmail(mail_user, [to_address], msg.as_string())
        server.quit()
        
        print(f"Email terkirim ke {to_address}")
        return True
    except Exception as e:
        print(f"Error mengirim email: {e}")
        return False

# Contoh penggunaan
send_email(
    'user@example.com',
    'Reset Password Anda',
    '<p>Klik <a href="https://app.example.com/reset?token=abc123">di sini</a> untuk reset password.</p>'
)
```

### Alternatif dengan STARTTLS (port 587)

Jika Anda lebih suka menggunakan port 587 dengan STARTTLS:

```python
import smtplib
# ...

server = smtplib.SMTP(mail_host, 587, timeout=10)  # tanpa _SSL
server.starttls()
server.login(mail_user, mail_pass)
# ... rest sama
```

## Menaikkan Rate Limit

Jika 200 pesan per jam tidak cukup, edit `config/plan.json.tpl`:

1. Temukan blok rate limit untuk aplikasi:
   ```json
   {
     "@type": "upsert",
     "object": "RateLimit",
     "matchOn": ["name"],
     "value": {
       "rl-app": {
         "name": "app-outbound",
         "accountId": "#acc-app",
         "messages": 200,
         "period": "1h"
       }
     }
   }
   ```

2. Ubah nilai `"messages"` ke nilai yang diinginkan (contoh: 500, 1000, dll)

3. Terapkan konfigurasi:
   ```bash
   make plan
   ```

4. Verifikasi perubahan diterapkan dengan melihat log:
   ```bash
   make logs
   ```

## Troubleshooting

### Koneksi ditolak
- Verifikasi `MAIL_HOSTNAME` benar dan menunjuk ke IP server
- Pastikan port 465 atau 587 terbuka di **security group Tencent** (atau firewall level-provider yang setara) — bukan `ufw` di dalam server, karena Docker mempublikasikan port lewat chain DNAT sendiri yang bypass rule INPUT host

### Autentikasi gagal
- Periksa kembali username dan password (case-sensitive)
- Pastikan `make plan` sudah dijalankan setelah perubahan .env

### Email tidak terkirim ke penerima
- Lihat log Stalwart: `make logs | grep -i mail`
- Periksa apakah Resend API key valid dan domain sudah diverifikasi di Resend
- Cek SPF/DKIM/DMARC dengan menggunakan `make verify`

### Mencapai rate limit
- Edit `config/plan.json.tpl` dan naikkan nilai `messages` seperti dijelaskan di atas
- Pertimbangkan untuk membagi beban antar waktu jika memungkinkan (batch processing)
