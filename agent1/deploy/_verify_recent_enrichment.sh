#!/bin/bash
set -eu

curl --noproxy '*' -sS -m 20 \
  'http://127.0.0.1:8101/api/status?day=2026-08-03' \
  -o /tmp/recent_enrichment.json

/home/admin-akea/agent1/venv/bin/python <<'PY'
import json

with open("/tmp/recent_enrichment.json", encoding="utf-8") as fh:
    data = json.load(fh)

rows = data.get("recent_results") or []
print("rows:", len(rows))
if rows:
    print("order_id:", rows[0].get("order_id"))
    print("site_address:", rows[0].get("site_address"))
    print("provider_name:", rows[0].get("provider_name"))
PY
