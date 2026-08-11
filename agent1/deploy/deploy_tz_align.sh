#!/bin/bash
set -euo pipefail
PASS="${1:-}"
ls ~/agent1/app/checklist_verdict.py ~/agent1/app/stage2.py
scp -i ~/.ssh/greta_ro -P 34023 -o IdentitiesOnly=yes -o BatchMode=yes \
  ~/agent1/greta/export_day.rb gretaadmin@greta.akea-ds.ru:~/agent1_export/export_day.rb
echo EXPORT_GRETA_OK
if [[ -n "$PASS" ]]; then
  echo "$PASS" | sudo -S systemctl restart agent1-api agent1-worker
  echo RESTART_OK
elif sudo -n systemctl restart agent1-api agent1-worker; then
  echo RESTART_OK
else
  echo RESTART_NEED_SUDO
fi
sleep 2
curl -sS -m 5 http://127.0.0.1:8101/api/health || true
echo
cd ~/agent1/app
../venv/bin/python <<'PY'
from checklist_verdict import compute_photo_verdict, VERDICT_VIOLATION
from stage2 import Checklist, route_checklist

r = compute_photo_verdict("1а", {"О3": 1, "А0": 1})
assert r.photo_verdict == VERDICT_VIOLATION
assert route_checklist(state="done", waste_type="ТБО", site_type="Сигнальный метод") == Checklist.SIGNAL
assert route_checklist(state="done", waste_type="ТБО", site_type="scheduled") == Checklist.SIGNAL
assert route_checklist(state="done", waste_type="ТБО", site_type="Контейнерная площадка") == Checklist.KP
assert route_checklist(state="done", waste_type="ТБО", site_type="containers") == Checklist.KP
print("SMOKE_OK", r.za_chto)
PY
curl -sS -m 5 http://127.0.0.1:8101/api/status | python3 -c 'import sys,json;d=json.load(sys.stdin);print("agreement_scope", bool(d.get("agreement_scope")));print("counts", {k:d.get("counts",{}).get(k) for k in ("not_in_work","failed_shift","compared_with_human")})'
systemctl is-active agent1-api agent1-worker agent1-daily.timer
echo DEPLOY_TZ_OK
