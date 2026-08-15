#!/usr/bin/env bash
# Loads and validates .env for every script in this repo.

REQUIRED_VARS=(
  MAIL_HOSTNAME MAIL_DOMAIN_1 MAIL_DOMAIN_2 MAIL_ADMIN_EMAIL
  MAIL_USER_1 MAIL_USER_1_PASS MAIL_APP_USER MAIL_APP_PASS
  CF_API_TOKEN RESEND_API_KEY ADMIN_ALLOW_IP STALWART_ADMIN_PASS
)

load_env() {
  local env_file="${1:-.env}"
  if [ ! -f "$env_file" ]; then
    echo "file $env_file tidak ada — salin dari .env.example dulu" >&2
    return 1
  fi
  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
  local missing=0
  for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
      echo "variabel $var belum diisi di $env_file" >&2
      missing=1
    fi
  done
  return "$missing"
}
