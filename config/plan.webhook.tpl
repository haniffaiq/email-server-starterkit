# Optional inbound webhook (Task 11). Only appended to config/plan.json by
# scripts/render-plan.sh when WEBHOOK_URL is set in .env; this comment line is
# stripped the same way as the comments in config/plan.json.tpl.
{"@type":"upsert","object":"Webhook","matchOn":["name"],"value":{"wh-inbound":{"name":"inbound-app","url":"${WEBHOOK_URL}","events":["message.accepted"]}}}
