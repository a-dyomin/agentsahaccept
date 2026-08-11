#!/bin/bash
set -eu
DAY="${1:-2026-08-03}"
curl --noproxy '*' -sS -m 20 "http://127.0.0.1:8101/api/status?day=$DAY" -o /tmp/st_day.json || true
/home/admin-akea/agent1/venv/bin/python <<'PY'
import json

try:
    d = json.load(open("/tmp/st_day.json"))
except Exception as exc:
    raise SystemExit(f"статус недоступен: {exc}")

c = d.get("counts", {})
print("состояние:", d.get("agent_state"))
print("очередь:", c.get("queued"), "| в работе:", c.get("in_progress"),
      "| готово:", c.get("processed"), "| ошибок:", c.get("errors"))
print("фото-нарушения: по содержанию", c.get("photo_by_content"),
      "| только ГЕО/трек", c.get("photo_by_geo_only"))
print("ИТОГ:")
for x in d.get("itog_distribution", []):
    print(f"   {x['itog']:<22} {x['n']}")
cost = d.get("costs") or {}
print("стоимость:", {k: v for k, v in cost.items() if "usd" in str(k) or "call" in str(k)})
PY
