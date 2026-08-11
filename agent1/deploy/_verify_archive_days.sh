#!/bin/bash
set -eu
sleep 3
systemctl is-active agent1-api
curl --noproxy '*' -sS -m 40 'http://127.0.0.1:8101/api/status?day=2026-08-04' -o /tmp/arch1.json
curl --noproxy '*' -sS -m 40 'http://127.0.0.1:8101/api/status' -o /tmp/arch2.json
/home/admin-akea/agent1/venv/bin/python <<'PY'
import json
a = json.load(open("/tmp/arch1.json", encoding="utf-8"))
b = json.load(open("/tmp/arch2.json", encoding="utf-8"))
print("with day filter:", a.get("available_days"))
print("no filter:", b.get("available_days"))
print("same:", a.get("available_days") == b.get("available_days"))
print("count filtered:", len(a.get("available_days") or []))
print("count all:", len(b.get("available_days") or []))
PY
