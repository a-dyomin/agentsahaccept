#!/bin/bash
set -eu
set -a
# shellcheck disable=SC1091
source /home/admin-akea/agent1/.env
set +a
DAY="2026-08-03"

echo "=== smoke: пометки кадров и полярность ==="
cd /home/admin-akea/agent1/app
../venv/bin/python - "$DAY" <<'PY'
import sys
sys.path.insert(0, "/home/admin-akea/agent1/app")
from checklist_verdict import POSITIVE_CODES, to_internal_answers
from stage2 import PTYPE_LABELS
print("  POSITIVE_CODES:", POSITIVE_CODES)
print("  PTYPE_LABELS  :", PTYPE_LABELS)
print("  модель О3=1 А4=1 Н5=1 ->", to_internal_answers({"О3": 1, "А4": 1, "Н5": 1}))
print("  модель О3=0 А4=0 Н5=0 ->", to_internal_answers({"О3": 0, "А4": 0, "Н5": 0}))
PY

echo
echo "=== чистим прошлый прогон за $DAY ==="
../venv/bin/python - "$DAY" <<'PY'
import os, sys
import psycopg
day = sys.argv[1]
url = next(os.environ[k] for k in ("DATABASE_URL", "AGENT1_DATABASE_URL", "AGENT1_DB_URL") if os.environ.get(k))
conn = psycopg.connect(url)
cur = conn.cursor()
for t in ("agent_decisions", "comparisons", "vision_usage", "results", "jobs", "runs"):
    try:
        cur.execute(f"DELETE FROM {t} WHERE day=%s::date", (day,))
        print(f"  {t}: удалено {cur.rowcount}")
    except Exception as exc:
        conn.rollback()
        print(f"  {t}: пропуск ({str(exc)[:60]})")
    else:
        conn.commit()
conn.close()
PY

echo
echo "=== перезапускаем сервисы с новым кодом ==="
pkill -f 'agent1.*worker' || true
pkill -f 'uvicorn.*main:app' || true
sleep 6
systemctl is-active agent1-api agent1-worker || true

echo
echo "=== ставим $DAY в очередь заново ==="
curl -s --noproxy '*' -X POST "http://127.0.0.1:8000/api/run/day/$DAY" || true
echo
sleep 20
curl -s --noproxy '*' "http://127.0.0.1:8000/api/status?day_from=$DAY&day_to=$DAY" \
  | ../venv/bin/python -c "import json,sys; d=json.load(sys.stdin); c=d.get('counts',{}); print('  очередь:',c.get('queued'),'в работе:',c.get('in_progress'),'готово:',c.get('processed'),'ошибок:',c.get('errors')); print('  фото-нарушения: по содержанию',c.get('photo_by_content'),'/ только ГЕО',c.get('photo_by_geo_only'))" || true
