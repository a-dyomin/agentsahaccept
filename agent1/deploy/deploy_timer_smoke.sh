#!/bin/bash
# Deploy D-2 timer at 01:00 Samara + optional vision smoke.
# Usage: bash deploy_timer_smoke.sh <sudo_password> [smoke_n]
set -euo pipefail
PASS="${1:?sudo password}"
SMOKE_N="${2:-30}"
A1=/home/admin-akea/agent1
DAY="${3:-2026-07-27}"

echo "$PASS" | sudo -S cp "$A1/deploy/agent1-daily.service" /etc/systemd/system/agent1-daily.service
echo "$PASS" | sudo -S cp "$A1/deploy/agent1-daily.timer" /etc/systemd/system/agent1-daily.timer
echo "$PASS" | sudo -S systemctl daemon-reload
echo "$PASS" | sudo -S systemctl enable --now agent1-daily.timer
systemctl list-timers agent1-daily.timer --no-pager | head -5
systemctl cat agent1-daily.timer | sed -n '1,20p'

# free a bit of photo cache before smoke
rm -rf "$A1/data/photos"/* 2>/dev/null || true
df -h / | tail -1

cd "$A1"
set -a; . ./.env; set +a
echo "=== enqueue smoke n=$SMOKE_N day=$DAY ==="
OUT=$(PYTHONPATH=app ./venv/bin/python /tmp/tmp_vision_smoke.py "$DAY" "$SMOKE_N")
echo "$OUT"
RUN_ID=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['run_id'])" "$OUT")
PYTHONPATH=app ./venv/bin/python /tmp/tmp_vision_smoke_wait.py "$RUN_ID" 1200 || true

# report from agent_decisions / vision_usage
PYTHONPATH=app ./venv/bin/python - <<PY
import json, os, urllib.request
import psycopg
from psycopg.rows import dict_row
RUN="$RUN_ID"
with psycopg.connect(os.environ["AGENT1_DATABASE_URL"], row_factory=dict_row) as conn:
    jobs=list(conn.execute("SELECT status, COUNT(*) n FROM jobs WHERE run_id=%s GROUP BY 1", (RUN,)))
    vu=conn.execute(
        "SELECT COUNT(*) n, COALESCE(SUM(total_tokens),0) tok, COALESCE(SUM(cost_usd),0) cost "
        "FROM vision_usage WHERE run_id=%s", (RUN,)
    ).fetchone()
    dist=list(conn.execute(
        "SELECT COALESCE(stage2->>'status','null') st, COUNT(*) n "
        "FROM agent_decisions WHERE run_id=%s GROUP BY 1 ORDER BY n DESC", (RUN,)
    ))
    sample=list(conn.execute(
        "SELECT order_id, stage2->>'status' s2, stage2->>'photo_verdict' pv, "
        "stage2->'usage' usage, LEFT(COALESCE(stage2->>'reason',''),100) reason "
        "FROM agent_decisions WHERE run_id=%s ORDER BY created_at DESC LIMIT 8", (RUN,)
    ))
print("jobs", [dict(x) for x in jobs])
print("vision_usage", dict(vu))
print("stage2_dist", [dict(x) for x in dist])
for s in sample:
    print("sample", dict(s))
with urllib.request.urlopen("http://127.0.0.1:8101/api/status?day=$DAY", timeout=30) as r:
    d=json.loads(r.read())
print("api_costs", d.get("costs"))
PY
echo TIMER_SMOKE_DONE
