#!/bin/bash
set -eu
set -a
# shellcheck disable=SC1091
source /home/admin-akea/agent1/.env
set +a

DAY=2026-08-04
APP=/home/admin-akea/agent1/app
PY=/home/admin-akea/agent1/venv/bin/python

echo "=== cancel and clean old run: $DAY ==="
cd "$APP"
"$PY" <<'PY'
import os
import psycopg
from psycopg.rows import dict_row

url = next(
    os.environ[k]
    for k in ("DATABASE_URL", "AGENT1_DATABASE_URL", "AGENT1_DB_URL")
    if os.environ.get(k)
)
day = "2026-08-04"
with psycopg.connect(url, row_factory=dict_row) as conn:
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO events(ts, level, message) VALUES (NOW(),'info',%s)",
        (
            f"rerun {day}: GPS фото при глушении заменяется подтверждением "
            "ТРЕК=1 (Wialon) + Stage2=ПОДТВЕРЖДЕНО",
        ),
    )
    cur.execute("SELECT id FROM runs WHERE day=%s", (day,))
    run_ids = [row["id"] for row in cur.fetchall()]
    print("runs:", len(run_ids))
    if run_ids:
        cur.execute("DELETE FROM results WHERE run_id = ANY(%s)", (run_ids,))
        print("results deleted:", cur.rowcount)
        cur.execute("DELETE FROM jobs WHERE run_id = ANY(%s)", (run_ids,))
        print("jobs deleted:", cur.rowcount)
    for table in ("agent_decisions", "comparisons", "vision_usage"):
        cur.execute(f"DELETE FROM {table} WHERE day=%s::date", (day,))
        print(f"{table} deleted:", cur.rowcount)
    cur.execute(
        "UPDATE runs SET status='cancelled', finished_at=NOW() "
        "WHERE day=%s AND status<>'cancelled'",
        (day,),
    )
    print("runs cancelled:", cur.rowcount)
    conn.commit()
PY

echo
echo "=== reload worker with new Stage1 ==="
PID=$(systemctl show -p MainPID --value agent1-worker)
if [ "${PID:-0}" != "0" ]; then
  kill "$PID"
fi
sleep 6
systemctl is-active agent1-worker

echo
echo "=== remove possible last old result and enqueue fresh ==="
"$PY" <<'PY'
import os
import psycopg
from ingest import enqueue_stage1

url = next(
    os.environ[k]
    for k in ("DATABASE_URL", "AGENT1_DATABASE_URL", "AGENT1_DB_URL")
    if os.environ.get(k)
)
day = "2026-08-04"
with psycopg.connect(url) as conn:
    for table in ("agent_decisions", "comparisons", "vision_usage"):
        conn.execute(f"DELETE FROM {table} WHERE day=%s::date", (day,))
    conn.commit()

run = enqueue_stage1(
    day,
    note="rerun: GPS фото fallback на Wialon + подтверждённые фото",
)
print("RUN", run)
PY

echo
echo "=== smoke after 30s ==="
sleep 30
curl --noproxy '*' -sS -m 20 \
  "http://127.0.0.1:8101/api/status?day=$DAY" \
  -o /tmp/status_0804_wialon.json
"$PY" <<'PY'
import json

with open("/tmp/status_0804_wialon.json", encoding="utf-8") as fh:
    data = json.load(fh)
counts = data.get("counts", {})
print("state:", data.get("agent_state"))
print(
    "queued:", counts.get("queued"),
    "in_progress:", counts.get("in_progress"),
    "processed:", counts.get("processed"),
    "errors:", counts.get("errors"),
)
print("active_run:", data.get("active_run"))
PY
echo REQUEUE_0804_OK
