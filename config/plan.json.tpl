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
{"@type":"update","object":"SystemSettings","value":{"defaultDomainId":"#dom-1"}}
{"@type":"upsert","object":"Account","matchOn":["name"],"value":{"acc-user":{"@type":"Individual","name":"${MAIL_USER_1}","description":"Mailbox pribadi","secrets":["${MAIL_USER_1_PASS}"],"emails":["${MAIL_USER_1}"]},"acc-app":{"@type":"Individual","name":"${MAIL_APP_USER}","description":"Akun aplikasi transaksional","secrets":["${MAIL_APP_PASS}"],"emails":["${MAIL_APP_USER}"]}}}
{"@type":"upsert","object":"DkimSignature","matchOn":["domainId","selector"],"value":{"dkim-1":{"domainId":"#dom-1","selector":"stalwart","algorithm":"Ed25519"},"dkim-2":{"domainId":"#dom-2","selector":"stalwart","algorithm":"Ed25519"}}}

# --- DNS provider, ACME, certificate management, listeners (Task 6) ---
{"@type":"upsert","object":"DnsServer","matchOn":["name"],"value":{"dns-cf":{"name":"cloudflare","@type":"Cloudflare","apiToken":"${CF_API_TOKEN}"}}}
{"@type":"upsert","object":"AcmeProvider","matchOn":["name"],"value":{"acme-le":{"name":"letsencrypt","directory":"https://acme-v02.api.letsencrypt.org/directory","challengeType":"Dns01","contact":{"${MAIL_ADMIN_EMAIL}":true},"renewBefore":"R23"}}}
{"@type":"update","object":"Domain","id":"#dom-1","value":{"certificateManagement":"Automatic","acmeProviderId":"#acme-le","dnsServerId":"#dns-cf","origin":"${MAIL_DOMAIN_1}"}}
{"@type":"update","object":"Domain","id":"#dom-2","value":{"certificateManagement":"Automatic","acmeProviderId":"#acme-le","dnsServerId":"#dns-cf","origin":"${MAIL_DOMAIN_2}"}}
{"@type":"upsert","object":"Listener","matchOn":["name"],"value":{"lsn-smtp":{"name":"smtp","protocol":"Smtp","bindAddress":"0.0.0.0","port":25,"tls":"Optional"},"lsn-submissions":{"name":"submissions","protocol":"Smtp","bindAddress":"0.0.0.0","port":465,"tls":"Implicit"},"lsn-submission":{"name":"submission","protocol":"Smtp","bindAddress":"0.0.0.0","port":587,"tls":"Required"},"lsn-imaps":{"name":"imaps","protocol":"Imap","bindAddress":"0.0.0.0","port":993,"tls":"Implicit"},"lsn-http":{"name":"http","protocol":"Http","bindAddress":"127.0.0.1","port":8080,"tls":"Disabled"}}}

# --- Outbound relay via Resend (Task 8) ---
{"@type":"upsert","object":"RelayHost","matchOn":["name"],"value":{"relay-resend":{"name":"resend","host":"smtp.resend.com","port":465,"tls":"Implicit","authUsername":"resend","authSecret":"${RESEND_API_KEY}"}}}
{"@type":"update","object":"SystemSettings","value":{"defaultRelayHostId":"#relay-resend"}}

# --- Rate limit for the application account (Task 10) ---
{"@type":"upsert","object":"RateLimit","matchOn":["name"],"value":{"rl-app":{"name":"app-outbound","accountId":"#acc-app","messages":200,"period":"1h"}}}
