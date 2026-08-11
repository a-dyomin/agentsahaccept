#!/bin/bash
# Deploy schedule enrich + backfill existing days. Usage: bash deploy_schedules_enrich.sh <sudo_password>
set -euo pipefail
PASS="${1:?sudo password}"
A1=/home/admin-akea/agent1

# push Greta exporters
scp -i ~/.ssh/greta_ro -P 34023 -o IdentitiesOnly=yes -o BatchMode=yes \
  "$A1/greta/export_day.rb" "$A1/greta/export_schedules_day.rb" \
  gretaadmin@greta.akea-ds.ru:~/agent1_export/

echo "$PASS" | sudo -S systemctl restart agent1-api
sleep 2
curl -sS --noproxy '*' http://127.0.0.1:8101/api/health; echo

cd "$A1"
for DAY in 2026-07-12 2026-07-27 2026-07-29; do
  echo "=== enrich $DAY ==="
  set -a; . ./.env; set +a
  PYTHONPATH=app ./venv/bin/python - <<PY
from ingest import enrich_schedules_day
print(enrich_schedules_day("$DAY"))
PY
done

PYTHONPATH=app ./venv/bin/python - <<'PY'
import os, psycopg
from psycopg.rows import dict_row
with psycopg.connect(os.environ["AGENT1_DATABASE_URL"], row_factory=dict_row) as c:
    print("schedules", list(c.execute(
        "SELECT day::text, COUNT(*) n, COUNT(DISTINCT vehicle_id) vehicles "
        "FROM schedules_day GROUP BY day ORDER BY day"
    )))
    print("photos_with_sched", list(c.execute(
        "SELECT day::text, COUNT(*) FILTER (WHERE schedule_id IS NOT NULL) with_s, COUNT(*) n "
        "FROM photos_day GROUP BY day ORDER BY day"
    )))
    print("sample", list(c.execute(
        "SELECT schedule_id, plate, state, start_at, route_id FROM schedules_day "
        "ORDER BY day DESC, schedule_id LIMIT 3"
    )))
PY
echo DEPLOY_SCHEDULES_OK
