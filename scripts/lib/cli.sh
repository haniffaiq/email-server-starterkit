#!/usr/bin/env bash
# Thin wrapper so every script talks to the local admin endpoint the same way.

STALWART_URL="${STALWART_URL:-http://127.0.0.1:8080}"

# Credentials go in via environment variables, not argv: a --password flag
# would sit in `ps aux` / /proc/<pid>/cmdline in plaintext for the lifetime of
# every `make plan`, visible to any local user. stalwart-cli reads
# STALWART_URL / STALWART_USER / STALWART_PASSWORD from its own environment,
# so we set them only for this one command's invocation.
#
# UNVERIFIED: the env var names above (STALWART_URL / STALWART_USER /
# STALWART_PASSWORD) have not been confirmed against a real stalwart-cli
# binary — they were taken from the task brief, not from the tool itself.
# Reconcile them against docs/reference/stalwart-schema.md and the output of
# `stalwart-cli --help` before relying on this in production. If the real
# names differ, stalwart-cli silently runs unauthenticated with no error from
# this wrapper alone — see the auth-failure detection below, which is the
# loud fallback for exactly that case.
swcli() {
  local errfile status
  errfile="$(mktemp)"
  STALWART_URL="$STALWART_URL" \
    STALWART_USER="admin" \
    STALWART_PASSWORD="$STALWART_ADMIN_PASS" \
    stalwart-cli "$@" 2>"$errfile"
  status=$?
  if [ "$status" -ne 0 ] && grep -qiE 'unauthor|401|authenticat' "$errfile"; then
    echo "swcli: autentikasi ke stalwart-cli gagal — nama variabel lingkungan kredensial (STALWART_URL/STALWART_USER/STALWART_PASSWORD) mungkin tidak cocok dengan versi CLI ini; cek dengan 'stalwart-cli --help'" >&2
  fi
  # Always pass the real stderr through unchanged (matches the pre-existing
  # behavior of running stalwart-cli directly); the hint above, if any, is
  # printed first so it's the first thing the operator sees.
  cat "$errfile" >&2
  rm -f "$errfile"
  return "$status"
}
