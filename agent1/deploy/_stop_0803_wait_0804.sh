#!/bin/bash
set -eu
set -a
# shellcheck disable=SC1091
source /home/admin-akea/agent1/.env
set +a

DAY=2026-08-03
echo "=== timers ==="
systemctl list-timers --all | grep -i agent1 || true
echo
systemctl cat agent1-daily.timer 2>/dev/null | sed -n '1,40p' || true
echo
echo "=== services ==="
systemctl is-active agent1-api agent1-worker agent1-daily.timer || true

echo
echo "=== status before stop ($DAY) ==="
curl --noproxy '*' -sS -m 15 "http://127.0.0.1:8101/api/status?day=$DAY" -o /tmp/st_before.json || true
/home/admin-akea/agent1/venv/bin/python <<'PY'
import json
try:
    d = json.load(open("/tmp/st_before.json"))
except Exception as exc:
    print("status unavailable:", exc)
else:
    c = d.get("counts", {})
    print("state:", d.get("agent_state"))
    print("queued:", c.get("queued"), "in_progress:", c.get("in_progress"), "processed:", c.get("processed"))
    print("active_run:", d.get("active_run"))
PY

echo
echo "=== cancel remaining jobs / runs for $DAY ==="
cd /home/admin-akea/agent1/app
../venv/bin/python <<'PY'
import os
import psycopg
from psycopg.rows import dict_row

url = next(
    os.environ[k]
    for k in ("DATABASE_URL", "AGENT1_DATABASE_URL", "AGENT1_DB_URL")
    if os.environ.get(k)
)
day = "2026-08-03"
with psycopg.connect(url, row_factory=dict_row) as conn:
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO events(ts, level, message) VALUES (NOW(),'info',%s)",
        (
            f"stop {day}: останавливаем прогон по запросу; "
            "ждём ночную выгрузку 2026-08-04 со всеми сегодняшними правками",
        ),
    )
    cur.execute("SELECT id, status FROM runs WHERE day=%s ORDER BY created_at DESC", (day,))
    runs = cur.fetchall()
    print("runs:", [(r["id"], r["status"]) for r in runs])
    run_ids = [r["id"] for r in runs]
    if run_ids:
        cur.execute(
            "SELECT status, COUNT(*)::int n FROM jobs WHERE run_id = ANY(%s) GROUP BY status ORDER BY n DESC",
            (run_ids,),
        )
        print("jobs before:", cur.fetchall())
        cur.execute(
            "DELETE FROM jobs WHERE run_id = ANY(%s) AND status IN ('queued','leased','error')",
            (run_ids,),
        )
        print("jobs deleted (queued/leased/error):", cur.rowcount)
        cur.execute(
            "UPDATE runs SET status='cancelled', finished_at=NOW() "
            "WHERE day=%s AND status NOT IN ('cancelled','done','finished')",
            (day,),
        )
        print("runs cancelled:", cur.rowcount)
    # also cancel any active non-day-tagged leftovers if schema has day on runs only
    cur.execute(
        "SELECT status, COUNT(*)::int n FROM jobs GROUP BY status ORDER BY n DESC"
    )
    print("jobs global after:", cur.fetchall())
    cur.execute(
        "SELECT id, day, status FROM runs WHERE status IN ('running','active','queued','processing') "
        "OR status NOT IN ('cancelled','done','finished') ORDER BY created_at DESC LIMIT 10"
    )
    print("open runs:", cur.fetchall())
    conn.commit()
PY

echo
echo "=== status after stop ==="
sleep 3
curl --noproxy '*' -sS -m 15 "http://127.0.0.1:8101/api/status?day=$DAY" -o /tmp/st_after.json || true
/home/admin-akea/agent1/venv/bin/python <<'PY'
import json
d = json.load(open("/tmp/st_after.json"))
c = d.get("counts", {})
print("state:", d.get("agent_state"))
print("queued:", c.get("queued"), "in_progress:", c.get("in_progress"), "processed:", c.get("processed"))
print("active_run:", d.get("active_run"))
print("labor_productivity_pct:", d.get("labor_productivity_pct"))
PY

echo
echo "=== next daily fire ==="
systemctl list-timers agent1-daily.timer --no-pager || true
echo STOP_OK
