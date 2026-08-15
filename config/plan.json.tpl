# Stalwart v0.16 declarative plan template.
#
# Field/object names below are taken verbatim from the task briefs in
# docs/superpowers/plans/2026-08-15-email-server.md and are UNVERIFIED against a
# live server. Task 4 (install `stalwart-cli`, run `swcli describe <Object>
# --json` against a running Stalwart instance, and record the real schema in
# docs/reference/stalwart-schema.md) is deferred to the operator. Before the
# first `make plan` run against a real server, reconcile every object/field
# name in this file against `swcli describe` output and fix any mismatches
# here, then note the corrections in docs/reference/stalwart-schema.md.
#
# Format: NDJSON — one JSON operation per line, no wrapping array. Lines in
# this file that start with `#` (this block included) and blank lines are
# comments/formatting only: scripts/render-plan.sh strips them before writing
# config/plan.json, so they never reach the rendered output or the server.

# --- Domains, default domain, accounts, DKIM (Task 5) ---
{"@type":"upsert","object":"Domain","matchOn":["name"],"value":{"dom-1":{"name":"${MAIL_DOMAIN_1}"},"dom-2":{"name":"${MAIL_DOMAIN_2}"}}}
{"@type":"upsert","object":"Account","matchOn":["name"],"value":{"acc-user":{"@type":"Individual","name":"${MAIL_USER_1}","description":"Mailbox pribadi","secrets":["${MAIL_USER_1_PASS}"],"emails":["${MAIL_USER_1}"]},"acc-app":{"@type":"Individual","name":"${MAIL_APP_USER}","description":"Akun aplikasi transaksional","secrets":["${MAIL_APP_PASS}"],"emails":["${MAIL_APP_USER}"]},"acc-user2":{"@type":"Individual","name":"${MAIL_USER_2}","description":"Mailbox domain kedua (#dom-2)","secrets":["${MAIL_USER_2_PASS}"],"emails":["${MAIL_USER_2}"]}}}
{"@type":"upsert","object":"DkimSignature","matchOn":["domainId","selector"],"value":{"dkim-1":{"domainId":"#dom-1","selector":"stalwart","algorithm":"Ed25519"},"dkim-2":{"domainId":"#dom-2","selector":"stalwart","algorithm":"Ed25519"}}}

# --- DNS provider, ACME, certificate management, listeners (Task 6) ---
{"@type":"upsert","object":"DnsServer","matchOn":["name"],"value":{"dns-cf":{"name":"cloudflare","@type":"Cloudflare","apiToken":"${CF_API_TOKEN}"}}}
{"@type":"upsert","object":"AcmeProvider","matchOn":["name"],"value":{"acme-le":{"name":"letsencrypt","directory":"https://acme-v02.api.letsencrypt.org/directory","challengeType":"Dns01","contact":{"${MAIL_ADMIN_EMAIL}":true},"renewBefore":"R23"}}}
{"@type":"update","object":"Domain","id":"#dom-1","value":{"certificateManagement":"Automatic","acmeProviderId":"#acme-le","dnsServerId":"#dns-cf","origin":"${MAIL_DOMAIN_1}"}}
{"@type":"update","object":"Domain","id":"#dom-2","value":{"certificateManagement":"Automatic","acmeProviderId":"#acme-le","dnsServerId":"#dns-cf","origin":"${MAIL_DOMAIN_2}"}}
# The HTTP admin listener (lsn-http) binds 0.0.0.0 *inside the container*, not
# host loopback — do NOT "fix" this back to 127.0.0.1. Docker publishes this
# port to the host as 127.0.0.1:8080 by DNAT'ing to the container's bridge IP,
# which is a different address than the container's own loopback. A listener
# bound to 127.0.0.1 inside the container only accepts connections from
# processes inside that same container's netns, so it silently refuses the
# DNAT'd traffic: the admin UI, nginx's proxy_pass, and every subsequent
# `swcli` call (including apply-plan.sh's own second, idempotency-check apply)
# would fail after the very first `make plan`. The real exposure control is
# docker-compose.yml publishing the port as "127.0.0.1:8080:8080", which
# keeps it unreachable from outside the host — see tests/render.bats.
{"@type":"upsert","object":"Listener","matchOn":["name"],"value":{"lsn-smtp":{"name":"smtp","protocol":"Smtp","bindAddress":"0.0.0.0","port":25,"tls":"Optional"},"lsn-submissions":{"name":"submissions","protocol":"Smtp","bindAddress":"0.0.0.0","port":465,"tls":"Implicit"},"lsn-submission":{"name":"submission","protocol":"Smtp","bindAddress":"0.0.0.0","port":587,"tls":"Required"},"lsn-imaps":{"name":"imaps","protocol":"Imap","bindAddress":"0.0.0.0","port":993,"tls":"Implicit"},"lsn-http":{"name":"http","protocol":"Http","bindAddress":"0.0.0.0","port":8080,"tls":"Disabled"}}}

# --- Outbound relay via Resend (Task 8) ---
{"@type":"upsert","object":"RelayHost","matchOn":["name"],"value":{"relay-resend":{"name":"resend","host":"smtp.resend.com","port":465,"tls":"Implicit","authUsername":"resend","authSecret":"${RESEND_API_KEY}"}}}

# SystemSettings is a singleton and `update` replaces rather than merges its
# value, so every field it needs must be set in ONE operation — two separate
# `update` calls would have the second silently drop the first's field, with
# apply reporting success either way. This line must come after every object
# it references (#dom-1, #relay-resend) is already defined above.
{"@type":"update","object":"SystemSettings","value":{"defaultDomainId":"#dom-1","defaultRelayHostId":"#relay-resend"}}

# --- Rate limit for the application account (Task 10) ---
{"@type":"upsert","object":"RateLimit","matchOn":["name"],"value":{"rl-app":{"name":"app-outbound","accountId":"#acc-app","messages":200,"period":"1h"}}}
