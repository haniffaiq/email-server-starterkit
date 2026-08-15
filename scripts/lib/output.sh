#!/usr/bin/env bash
# Shared pass/fail reporting used by every script in this repo.

FAIL_COUNT=${FAIL_COUNT:-0}
PASS_COUNT=${PASS_COUNT:-0}

ok()   { printf '  \033[32mOK\033[0m    %s\n' "$1"; PASS_COUNT=$((PASS_COUNT + 1)); return 0; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; return 0; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL_COUNT=$((FAIL_COUNT + 1)); return 0; }

summary() {
  printf '\n%s lulus, %s gagal\n' "$PASS_COUNT" "$FAIL_COUNT"
  [ "$FAIL_COUNT" -eq 0 ] || exit 1
}
