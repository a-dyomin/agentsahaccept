#!/bin/bash
set -eu
set -a
# shellcheck disable=SC1091
source /home/admin-akea/agent1/.env
set +a
/home/admin-akea/agent1/venv/bin/python <<'PY'
import os
import psycopg
from psycopg.rows import dict_row

url = next(os.environ[k] for k in ("DATABASE_URL", "AGENT1_DATABASE_URL", "AGENT1_DB_URL") if os.environ.get(k))
with psycopg.connect(url, row_factory=dict_row) as conn:
    cur = conn.cursor()
    cur.execute("SELECT status, COUNT(*)::int n FROM jobs GROUP BY status ORDER BY n DESC")
    print("JOBS", cur.fetchall())
    cur.execute(
        "SELECT r.day::text d, j.status, COUNT(*)::int n "
        "FROM jobs j JOIN runs r ON r.id=j.run_id "
        "WHERE j.status IN ('queued','leased','error') "
        "GROUP BY 1,2 ORDER BY 1,2"
    )
    print("QUEUE_BY_DAY", cur.fetchall())
    cur.execute(
        "SELECT day::text d, COUNT(*)::int n, MAX(created_at)::text last_at "
        "FROM agent_decisions GROUP BY 1 ORDER BY 1 DESC LIMIT 8"
    )
    print("DECISIONS_BY_DAY")
    for r in cur.fetchall():
        print(" ", r)
    for mins in (10, 60, 360):
        cur.execute(
            "SELECT COUNT(*)::int n FROM agent_decisions "
            "WHERE created_at > now() - (%s || ' minutes')::interval",
            (mins,),
        )
        n = cur.fetchone()["n"]
        print(f"THROUGHPUT_LAST_{mins}MIN", n, "=> per_hour", round(n * 60.0 / mins, 1))
    cur.execute(
        "SELECT id::text, order_id, status, leased_at::text, "
        "ROUND(EXTRACT(EPOCH FROM (now()-leased_at))/3600.0,1) hours_leased "
        "FROM jobs WHERE status='leased'"
    )
    print("LEASED", cur.fetchall())
    q = cur.execute("SELECT COUNT(*)::int n FROM jobs WHERE status='queued'").fetchone()["n"]
    print("QUEUED", q, "ETA_H_AT_1700", round(q / 1700, 1) if q else 0)
PY
echo "=== worker recent done ==="
journalctl -u agent1-worker -n 50 --no-pager | grep 'done order=' | tail -10 || true
echo DONE
