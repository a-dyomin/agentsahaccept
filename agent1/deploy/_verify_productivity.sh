#!/bin/bash
set -eu

curl --noproxy '*' -sS -m 20 \
  'http://127.0.0.1:8101/api/status?day=2026-08-03' \
  -o /tmp/kpi_status.json

/home/admin-akea/agent1/venv/bin/python <<'PY'
import json

with open("/tmp/kpi_status.json", encoding="utf-8") as fh:
    data = json.load(fh)

counts = data.get("counts", {})
print("labor_productivity_pct:", data.get("labor_productivity_pct"))
print("auto_checked:", counts.get("auto_checked"))
print("sent_to_human:", counts.get("sent_to_human"))
PY
