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
  local errfile status tee_pid
  errfile="$(mktemp)"

  # Stream stderr through to the real stderr as stalwart-cli produces it,
  # instead of buffering it all into a file and dumping it at the end. A
  # long call (e.g. `swcli apply`) needs to show progress/warnings live,
  # and if stalwart-cli ever prompts for credentials on stderr while stdin
  # blocks, that prompt must be visible immediately or the operator just
  # sees a silent hang. `tee` fans the stream out to both the real stderr
  # (fd 2, via >&2) and $errfile, so the auth-failure check below still has
  # a copy to inspect once the command is done.
  #
  # `exec 9> >(tee "$errfile" >&2)` starts `tee` as a genuine background
  # job — its PID lands in $! — so we can `wait` on it after closing our
  # end of fd 9. Process substitutions are not waited on automatically the
  # way background jobs are, so without this there is a race where
  # stalwart-cli has exited but `tee` hasn't finished flushing its last
  # write(s) to $errfile yet, and the auth check below would read a
  # partial (or still-empty) file.
  exec 9> >(tee "$errfile" >&2)
  tee_pid=$!

  STALWART_URL="$STALWART_URL" \
    STALWART_USER="admin" \
    STALWART_PASSWORD="$STALWART_ADMIN_PASS" \
    stalwart-cli "$@" 2>&9
  status=$?

  # Close our end of the pipe so `tee` sees EOF, then wait for it to finish
  # writing $errfile before we inspect it.
  exec 9>&-
  wait "$tee_pid" 2>/dev/null

  # The hint (if any) necessarily prints after the real stderr now, since
  # streaming means the real output is already on its way out live and we
  # only know whether this was an auth failure once the command has
  # finished and $errfile is complete.
  if [ "$status" -ne 0 ] && grep -qiE 'unauthor|401|authenticat' "$errfile"; then
    echo "swcli: autentikasi ke stalwart-cli gagal — nama variabel lingkungan kredensial (STALWART_URL/STALWART_USER/STALWART_PASSWORD) mungkin tidak cocok dengan versi CLI ini; cek dengan 'stalwart-cli --help'" >&2
  fi
  rm -f "$errfile"
  return "$status"
}
