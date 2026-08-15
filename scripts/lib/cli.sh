#!/usr/bin/env bash
# Thin wrapper so every script talks to the local admin endpoint the same way.

STALWART_URL="${STALWART_URL:-http://127.0.0.1:8080}"

swcli() {
  stalwart-cli --url "$STALWART_URL" \
    --user admin --password "$STALWART_ADMIN_PASS" "$@"
}
