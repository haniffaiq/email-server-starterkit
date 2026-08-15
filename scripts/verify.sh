#!/usr/bin/env bash
# End-to-end health check: can this server send, receive, and stay closed to abuse?

# --- Pure verdict functions -------------------------------------------------
# Kept free of any I/O so they can be unit-tested (see tests/verify.bats)
# without a live server, docker, or a .env file.

# Isolate the RCPT TO reply from a full SMTP transcript (greeting through
# QUIT). Positional line indexing (e.g. taking a fixed line number with
# sed) is wrong the moment any earlier reply spans more than one line, so
# instead this groups the transcript into individual responses: a line is
# the last line of its response unless its 4th character is '-' (an SMTP
# multi-line continuation, e.g. "250-STARTTLS"), and each such group is
# one reply.
# The commands this repo sends are, in order: HELO/EHLO, MAIL FROM,
# RCPT TO, QUIT — so counting from the greeting (index 0), the RCPT TO
# reply is always response index 3, however many lines each earlier reply
# took. If fewer than 4 responses were received (e.g. the server closed
# the connection early), there is no RCPT reply to report.
# Reads the transcript from $1 if given, otherwise from stdin.
smtp_rcpt_response() {
  local transcript
  if [ "$#" -ge 1 ]; then
    transcript="$1"
  else
    transcript="$(cat)"
  fi

  local -a responses=()
  local current=""
  local line
  # Process substitution (not a here-string): a here-string unconditionally
  # appends a trailing newline, which would fabricate a spurious empty
  # final response whenever the transcript already ends in \r\n. The
  # `|| [ -n "$line" ]` clause still processes a genuinely unterminated
  # final line (e.g. the connection was cut mid-response).
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    current="${current:+$current$'\n'}$line"
    if [ "${line:3:1}" != '-' ]; then
      responses+=("$current")
      current=""
    fi
  done < <(printf '%s' "$transcript")

  if [ "${#responses[@]}" -lt 4 ]; then
    return 1
  fi
  printf '%s\n' "${responses[3]}"
}

# Classify a single, already-isolated SMTP RCPT TO response line (see
# smtp_rcpt_response above for how that line is isolated from a full
# transcript). Any 2xx code means the server accepted a relay to a
# foreign domain without authentication — that is an open relay,
# regardless of which exact wording (e.g. Stalwart's "250 2.1.5 OK") the
# server used.
smtp_relay_verdict() {
  local resp="${1:-}"
  if [ -z "$resp" ]; then
    echo "INCONCLUSIVE"
    return 1
  fi
  if printf '%s\n' "$resp" | grep -qE '^2[0-9]{2}[ -]'; then
    echo "OPEN_RELAY"
    return 1
  fi
  echo "SAFE"
  return 0
}

# Classify an IMAP transcript by looking specifically at the LOGIN
# command's own tagged response (a1), never at LOGOUT's (a2). LOGIN and
# LOGOUT must use different tags, otherwise a rejected login can be
# masked by the LOGOUT command's unrelated "OK".
imap_login_verdict() {
  local transcript="${1:-}"
  if [ -z "$transcript" ]; then
    echo "INCONCLUSIVE"
    return 1
  fi
  if printf '%s\n' "$transcript" | grep -q '^a1 OK'; then
    echo "LOGIN_OK"
    return 0
  fi
  echo "LOGIN_FAILED"
  return 1
}

# Encode a raw string as an IMAP quoted-string literal per RFC 3501:
# backslash and double-quote are backslash-escaped, and the result is
# wrapped in double quotes. Used for the LOGIN password so that a space
# or a literal double quote in it cannot break the command line (backslash
# must be escaped first, otherwise the quote-escaping step's own inserted
# backslashes would get re-escaped).
imap_quote_literal() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

# --- Main check sequence ----------------------------------------------------
# Wrapped in a function and guarded below so this file can be sourced (by
# bats, or interactively) to reuse the verdict functions above without
# running the live checks or requiring a .env / docker / network.
main() {
  set -uo pipefail
  cd "$(dirname "${BASH_SOURCE[0]}")/.."
  source scripts/lib/output.sh
  source scripts/lib/env.sh
  load_env

  echo "== Verifikasi mail server =="

  # 0. Tooling required by later checks. Without these, a check would
  #    either crash or silently report success on missing output — worse
  #    than not running at all, since the operator would trust a result
  #    that was never actually produced.
  local have_nc=1
  local have_dig=1
  if ! command -v nc >/dev/null 2>&1; then
    fail "'nc' (netcat) tidak terpasang — tes open-relay TIDAK BISA dijalankan. Pasang dulu, mis: apt install netcat-openbsd"
    have_nc=0
  fi
  if ! command -v dig >/dev/null 2>&1; then
    fail "'dig' tidak terpasang — tes DNS TIDAK BISA dijalankan. Pasang dulu, mis: apt install dnsutils"
    have_dig=0
  fi

  # 1. Container alive.
  docker compose ps --status running | grep -q stalwart \
    && ok "container jalan" || fail "container mati"

  # 2. Inbound port 25 listening.
  ss -tlnp 2>/dev/null | grep -q ':25 ' \
    && ok "port 25 didengarkan" || fail "tidak ada yang dengar di port 25"

  # 3. Certificate valid on the submission port.
  #    NOTE: this probe runs from the server itself to its own public
  #    hostname (${MAIL_HOSTNAME}:465). Behind Tencent Lighthouse's 1:1
  #    NAT, hairpin NAT (reaching your own public IP from inside) is not
  #    guaranteed, so a healthy server can still report FAIL here. The
  #    authoritative check is from a host OUTSIDE this network.
  cert=$(openssl s_client -connect "${MAIL_HOSTNAME}:465" -servername "${MAIL_HOSTNAME}" \
          </dev/null 2>/dev/null | openssl x509 -noout -subject -dates 2>/dev/null)
  if echo "$cert" | grep -q "$MAIL_HOSTNAME"; then
    ok "sertifikat TLS cocok dengan $MAIL_HOSTNAME"
  else
    fail "sertifikat TLS tidak cocok atau tidak ada — CATATAN: probe ini jalan dari server ke hostname publiknya sendiri, dan di belakang NAT 1:1 Tencent Lighthouse, NAT hairpin tidak selalu didukung — server yang sehat pun bisa gagal di sini. Pemeriksaan yang otoritatif HANYA valid dari host di LUAR jaringan ini."
  fi

  # 4. IMAP login works. LOGIN and LOGOUT use distinct tags (a1/a2) so a
  #    rejected login can't be masked by LOGOUT's unrelated "OK".
  #    Password is passed to openssl, never printed.
  #    IMAP requires CRLF line endings (a bare LF heredoc is invalid
  #    protocol framing), and the password is sent as a quoted string
  #    literal — not interpolated raw — so a space or a double quote in
  #    it can't break the LOGIN command.
  #    Same NAT-hairpin caveat as the TLS check above applies here (port 993).
  local imap_pass_quoted
  imap_pass_quoted="$(imap_quote_literal "$MAIL_USER_1_PASS")"
  imap_transcript=$(printf 'a1 LOGIN %s %s\r\na2 LOGOUT\r\n' "$MAIL_USER_1" "$imap_pass_quoted" \
          | openssl s_client -connect "${MAIL_HOSTNAME}:993" -quiet 2>/dev/null)
  imap_verdict=$(imap_login_verdict "$imap_transcript")
  if [ "$imap_verdict" = "LOGIN_OK" ]; then
    ok "login IMAP berhasil"
  else
    fail "login IMAP gagal — CATATAN: probe ini jalan dari server ke hostname publiknya sendiri (port 993), dan di belakang NAT 1:1 Tencent Lighthouse, NAT hairpin tidak selalu didukung — server yang sehat pun bisa gagal di sini. Pemeriksaan yang otoritatif HANYA valid dari host di LUAR jaringan ini."
  fi

  # 5. Open relay test: relaying to a foreign domain without auth must be
  #    refused. The RCPT TO reply is isolated with smtp_rcpt_response,
  #    which correlates SMTP responses (collapsing multi-line replies)
  #    rather than indexing raw text lines — a fixed line number breaks
  #    the moment the greeting or HELO/EHLO reply spans more than one line.
  if [ "$have_nc" -eq 1 ]; then
    relay_transcript=$(printf 'HELO test\r\nMAIL FROM:<probe@example.org>\r\nRCPT TO:<probe@gmail.com>\r\nQUIT\r\n' \
            | timeout 15 nc 127.0.0.1 25 2>/dev/null)
    relay_rcpt_resp=$(smtp_rcpt_response "$relay_transcript")
    relay_verdict=$(smtp_relay_verdict "$relay_rcpt_resp")
    case "$relay_verdict" in
      OPEN_RELAY)
        fail "OPEN RELAY — server menerima relay tanpa auth (respons RCPT: ${relay_rcpt_resp:-kosong}), MATIKAN port 25 sekarang dan perbaiki. Catatan: probe ini dari loopback (127.0.0.1) — sifatnya indikatif saja, WAJIB dikonfirmasi dari luar jaringan (mis. MXToolbox open relay test) sebelum go-live."
        ;;
      SAFE)
        ok "open-relay test negatif (relay tanpa auth ditolak) — catatan: probe loopback ini sifatnya indikatif saja, konfirmasi dari luar jaringan (mis. MXToolbox open relay test) sebelum go-live"
        ;;
      *)
        fail "open-relay test tidak bisa disimpulkan (tidak ada respons dari server saat RCPT TO) — periksa port 25 lalu coba lagi. Probe ini juga hanya indikatif dari loopback; konfirmasi dari luar jaringan sebelum go-live."
        ;;
    esac
  fi

  # 6. DNS records present.
  if [ "$have_dig" -eq 1 ]; then
    for d in "$MAIL_DOMAIN_1" "$MAIL_DOMAIN_2"; do
      dig +short MX "$d" | grep -q "$MAIL_HOSTNAME" \
        && ok "MX $d benar" || fail "MX $d belum menunjuk $MAIL_HOSTNAME"
      dig +short TXT "$d" | grep -q 'v=spf1' \
        && ok "SPF $d ada" || fail "SPF $d belum ada"
      dig +short TXT "_dmarc.$d" | grep -q 'v=DMARC1' \
        && ok "DMARC $d ada" || fail "DMARC $d belum ada"
    done
  fi

  # 7. Memory headroom. docker stats MemPerc includes page cache, which
  #    RocksDB routinely fills as it's used — a high number alone is not a
  #    problem, so the threshold is set well above normal cache pressure
  #    to avoid training the operator to ignore this warning.
  mem=$(docker stats --no-stream --format '{{.MemPerc}}' stalwart 2>/dev/null | tr -d '%' | cut -d. -f1)
  if [ -n "$mem" ] && [ "$mem" -lt 95 ]; then
    ok "memori container ${mem}% dari limit"
  else
    warn "memori container ${mem}% dari limit — sebagian besar biasanya page cache (wajar untuk RocksDB), bukan tanda bahaya; hanya perlu tindakan kalau container benar-benar di-OOM-kill"
  fi

  summary
}

# Only run the live checks when this file is executed directly, not when
# it is sourced (e.g. by tests) to reuse the verdict functions above.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
