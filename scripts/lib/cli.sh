#!/usr/bin/env bash
# Thin wrapper so every script talks to the local admin endpoint the same way.

STALWART_URL="${STALWART_URL:-http://127.0.0.1:8080}"

# Credentials go in via environment variables, not argv: a --password flag
# would sit in `ps aux` / /proc/<pid>/cmdline in plaintext for the lifetime of
# every `make plan`, visible to any local user. stalwart-cli reads
# STALWART_URL / STALWART_USER / STALWART_PASSWORD from its own environment,
# so we set them only for this one command's invocation.
swcli() {
  STALWART_URL="$STALWART_URL" \
    STALWART_USER="admin" \
    STALWART_PASSWORD="$STALWART_ADMIN_PASS" \
    stalwart-cli "$@"
}
