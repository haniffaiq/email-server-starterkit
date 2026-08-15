# Pemrosesan Email Masuk

Panduan ini menjelaskan dua cara untuk mengirimkan email masuk ke aplikasi Anda: melalui webhook realtime atau polling IMAP berkala.

## Ikhtisar

Setelah email diterima oleh mail server dan tersimpan di RocksDB, aplikasi Anda dapat mengaksesnya dengan dua cara:

1. **Webhook** — server mengirim notifikasi HTTP POST ke endpoint aplikasi setiap kali email diterima. Realtime namun memerlukan endpoint publik.
2. **Polling IMAP** — aplikasi menghubungkan ke server secara berkala, membaca email yang belum dibaca, memproses, dan menandainya sudah dibaca. Sederhana dan tidak butuh endpoint publik.

Pilih jalur yang sesuai dengan arsitektur aplikasi Anda.

## Jalur 1: Webhook

### Pengaturan

Edit file `.env` dan isi `WEBHOOK_URL`:

```bash
WEBHOOK_URL=https://app.example.com/webhook/mail
```

Endpoint ini harus:
- **Dapat diakses dari internet** — server harus bisa mengirim HTTP POST ke URL ini
- **Menerima HTTPS** — koneksi harus aman
- **Respons cepat** — jangan biarkan request menggantung
- **Idempoten** — jika endpoint menerima pesan yang sama dua kali, harus menanganinya dengan benar

Setelah mengisi `WEBHOOK_URL`, terapkan konfigurasi:

```bash
make plan
```

Log Stalwart akan menunjukkan webhook telah diaktifkan:
```bash
make logs | grep -i webhook
```

### Format Payload Webhook

Ketika email diterima, server mengirim POST ke endpoint dengan struktur seperti berikut:

```json
{
  "event": "message.accepted",
  "message": {
    "id": "...",
    "from": "sender@example.com",
    "to": ["recipient@yourdomain.com"],
    "subject": "Contoh Subject",
    "date": "2026-08-15T10:30:00Z",
    "size": 2048,
    "flags": []
  }
}
```

**Catatan penting:** Struktur payload untuk Stalwart v0.16 mungkin berbeda dari dokumentasi resmi. Untuk mengetahui format pasti yang dikirim oleh server Anda, lakukan tes seperti berikut:

1. Jalankan webhook catcher lokal di terminal server:
   ```bash
   docker run --rm -p 9000:8080 ghcr.io/tarampampam/webhook-tester:latest
   ```

2. Edit `.env`:
   ```bash
   WEBHOOK_URL=http://127.0.0.1:9000/
   make plan
   ```

3. Kirim email test dari Gmail ke `${MAIL_USER_1}`:
   ```bash
   echo "Ini email test" | mail -s "Test webhook" ${MAIL_USER_1}
   ```

4. Lihat terminal webhook catcher — payload yang diterima adalah format sebenarnya yang digunakan server Anda.

5. Catat format payload di dokumentasi internal Anda, dan sesuaikan parsing code dengan format tersebut.

### Contoh Handler Webhook (Node.js Express)

```javascript
const express = require('express');
const app = express();

app.use(express.json());

app.post('/webhook/mail', (req, res) => {
  const payload = req.body;
  
  // Verifikasi bahwa ini adalah webhook mail yang diharapkan
  if (payload.event !== 'message.accepted') {
    return res.status(400).json({ error: 'unexpected event' });
  }
  
  const { message } = payload;
  
  console.log(`Email diterima dari ${message.from} ke ${message.to.join(', ')}`);
  console.log(`Subject: ${message.subject}`);
  
  // Proses email di sini
  // Contoh: simpan ke database, trigger notifikasi, dll
  handleEmailInApp(message);
  
  // Respons 200 OK untuk memberi tahu server bahwa webhook berhasil diproses
  res.json({ status: 'processed' });
});

function handleEmailInApp(message) {
  // Implementasi logika aplikasi Anda
  console.log('Processing:', message);
}

app.listen(3000, () => console.log('Webhook listening on :3000'));
```

### Idempotency

**Penting:** Server mungkin mengirim webhook yang sama lebih dari satu kali dalam kasus-kasus tertentu (retry, network timeout, dll). Endpoint Anda harus **idempoten** — memproses pesan yang sama dua kali tidak boleh membuat duplikat di sistem Anda.

Strategi idempotency:

```javascript
// Simpan ID pesan yang sudah diproses
const processedIds = new Set();

app.post('/webhook/mail', (req, res) => {
  const { message } = req.body;
  
  // Jika sudah pernah diproses, return 200 OK tapi jangan proses ulang
  if (processedIds.has(message.id)) {
    return res.json({ status: 'already_processed' });
  }
  
  // Proses untuk pertama kalinya
  handleEmailInApp(message);
  processedIds.add(message.id);
  
  res.json({ status: 'processed' });
});
```

Atau lebih baik, simpan ke database dengan unique constraint pada message ID:

```javascript
app.post('/webhook/mail', async (req, res) => {
  const { message } = req.body;
  
  try {
    // Simpan ke database dengan unique constraint pada email_id
    await db.query(
      'INSERT INTO received_emails (email_id, from_addr, subject) VALUES (?, ?, ?)',
      [message.id, message.from, message.subject]
    );
    
    res.json({ status: 'processed' });
  } catch (err) {
    // Jika email_id sudah ada (unique constraint), return 200 OK (bukan error)
    if (err.code === 'ER_DUP_ENTRY') {
      return res.json({ status: 'already_processed' });
    }
    
    // Untuk error lain, return 500 agar server retry nanti
    console.error('Database error:', err);
    res.status(500).json({ error: 'database error' });
  }
});
```

## Jalur 2: Polling IMAP

Jika Anda tidak punya endpoint publik atau lebih suka pendekatan pull (tarik) daripada push (dorong), gunakan polling IMAP. Aplikasi Anda terhubung ke server secara berkala, membaca email baru, memproses, dan menandai sebagai sudah dibaca.

### Keuntungan Polling IMAP

- **Tidak butuh endpoint publik** — aplikasi hanya mengirim koneksi keluar ke server
- **Kontrol penuh** — Anda menentukan kapan membaca dan dengan kecepatan berapa
- **Fault tolerance** — jika aplikasi down, email menumpuk di server (aman)

### Konfigurasi IMAP

Untuk polling IMAP, buat akun terpisah di `.env` jika belum ada:

```bash
# Akun khusus untuk polling (opsional, atau pakai MAIL_USER_1)
MAIL_POLLING_USER=inbox@domain-utama.com
MAIL_POLLING_PASS=password-untuk-inbox
```

Akun ini dapat berupa mailbox pribadi (MAIL_USER_1) atau akun terpisah. Penting agar akun memiliki akses IMAP penuh.

### Contoh Polling IMAP — Python

```python
import imaplib
import email
from email.parser import Parser
import os
import time
import json
from datetime import datetime

class MailPoller:
    def __init__(self, host, port, username, password):
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.conn = None
    
    def connect(self):
        """Establish IMAP connection."""
        self.conn = imaplib.IMAP4_SSL(self.host, self.port)
        self.conn.login(self.username, self.password)
        print(f"Connected as {self.username}")
    
    def disconnect(self):
        """Close IMAP connection."""
        if self.conn:
            self.conn.close()
            self.conn = None
    
    def poll_unseen(self, mailbox='INBOX'):
        """
        Fetch and process unseen messages.
        """
        if not self.conn:
            self.connect()
        
        try:
            # Select mailbox
            status, _ = self.conn.select(mailbox)
            if status != 'OK':
                print(f"Failed to select {mailbox}")
                return
            
            # Search for unseen messages
            status, uids = self.conn.search(None, 'UNSEEN')
            if status != 'OK' or not uids[0]:
                print(f"No unseen messages in {mailbox}")
                return
            
            # Fetch each unseen message
            uid_list = uids[0].split()
            print(f"Found {len(uid_list)} unseen messages")
            
            for uid in uid_list:
                status, msg_data = self.conn.fetch(uid, '(RFC822)')
                if status != 'OK':
                    continue
                
                # Parse email
                raw_email = msg_data[0][1]
                msg = Parser().parsestr(raw_email.decode('utf-8', errors='ignore'))
                
                # Extract relevant fields
                email_info = {
                    'uid': uid.decode(),
                    'from': msg.get('From', ''),
                    'to': msg.get('To', ''),
                    'subject': msg.get('Subject', ''),
                    'date': msg.get('Date', ''),
                    'body': self.get_body(msg),
                    'received_at': datetime.now().isoformat()
                }
                
                print(f"Processing email from {email_info['from']}: {email_info['subject']}")
                
                # Process email in your application
                self.handle_email(email_info)
                
                # Mark as seen after successful processing
                self.conn.store(uid, '+FLAGS', '\\Seen')
                print(f"Marked UID {uid.decode()} as seen")
        
        except Exception as e:
            print(f"Error polling: {e}")
            # Reconnect for next attempt
            self.disconnect()
    
    def get_body(self, msg):
        """Extract email body (plain text or HTML)."""
        body = None
        
        if msg.is_multipart():
            for part in msg.walk():
                if part.get_content_type() == 'text/plain':
                    body = part.get_payload(decode=True).decode('utf-8', errors='ignore')
                    break
                elif part.get_content_type() == 'text/html' and not body:
                    body = part.get_payload(decode=True).decode('utf-8', errors='ignore')
        else:
            body = msg.get_payload(decode=True).decode('utf-8', errors='ignore')
        
        return body or ''
    
    def handle_email(self, email_info):
        """
        Process received email.
        Override this method with your application logic.
        """
        # Contoh: simpan ke database
        print(f"Handling email: {json.dumps(email_info, indent=2)}")
        
        # Contoh logic: simpan ke file
        with open(f"email_{email_info['uid']}.json", 'w') as f:
            json.dump(email_info, f, indent=2)


def main():
    """Main polling loop."""
    # Konfigurasi dari environment
    mail_host = os.getenv('MAIL_HOSTNAME')           # mail.domain-utama.com
    mail_port = 993                                   # IMAP dengan TLS
    mail_user = os.getenv('MAIL_POLLING_USER')       # inbox@domain-utama.com
    mail_pass = os.getenv('MAIL_POLLING_PASS')       # password
    
    # Atau gunakan mailbox pribadi
    # mail_user = os.getenv('MAIL_USER_1')
    # mail_pass = os.getenv('MAIL_USER_1_PASS')
    
    poller = MailPoller(mail_host, mail_port, mail_user, mail_pass)
    
    # Poll every 30 seconds
    poll_interval = 30  # seconds
    
    try:
        while True:
            print(f"\n--- Poll at {datetime.now()} ---")
            poller.poll_unseen()
            time.sleep(poll_interval)
    except KeyboardInterrupt:
        print("Stopping...")
        poller.disconnect()


if __name__ == '__main__':
    main()
```

### Menjalankan Poller

Simpan script di atas sebagai `mail_poller.py` dan jalankan:

```bash
# Set environment variables
export MAIL_HOSTNAME=mail.domain-utama.com
export MAIL_POLLING_USER=inbox@domain-utama.com
export MAIL_POLLING_PASS=password-anda

# Run poller
python3 mail_poller.py
```

Untuk deployment, gunakan process manager seperti `supervisor` atau `systemd`:

```ini
# /etc/supervisor/conf.d/mail_poller.conf
[program:mail_poller]
directory=/opt/app
command=python3 mail_poller.py
autostart=true
autorestart=true
stderr_logfile=/var/log/mail_poller.err.log
stdout_logfile=/var/log/mail_poller.out.log
environment=
  MAIL_HOSTNAME="mail.domain-utama.com",
  MAIL_POLLING_USER="inbox@domain-utama.com",
  MAIL_POLLING_PASS="password-anda"
```

## Perbandingan Webhook vs Polling

| Aspek | Webhook | Polling IMAP |
|-------|---------|-------------|
| **Realtime** | Ya, segera setelah email diterima | Tidak, ada delay polling interval |
| **Endpoint publik diperlukan** | Ya | Tidak |
| **Kompleksitas** | Lebih tinggi (handle retry, idempotency) | Sederhana (hanya baca dan tandai) |
| **Beban server** | Rendah di server mail, bisa tinggi di app | Rendah, konsisten |
| **Fault tolerance** | Bergantung pada retry logic | Lebih baik, email menumpuk aman di server |
| **Keamanan** | Lebih terbuka (endpoint publik) | Hanya koneksi keluar dari app |

Pilih webhook jika Anda butuh realtime dan punya endpoint publik yang andal. Pilih polling jika Anda menghargai kesederhanaan dan tidak butuh notifikasi instant.
