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

url = None
for k in ("DATABASE_URL", "AGENT1_DATABASE_URL", "AGENT1_DB_URL"):
    if os.environ.get(k):
        url = os.environ[k]
        break
if not url:
    url = (
        f"postgresql://{os.environ.get('PGUSER','agent1')}:"
        f"{os.environ.get('PGPASSWORD','')}@"
        f"{os.environ.get('PGHOST','127.0.0.1')}:"
        f"{os.environ.get('PGPORT','5432')}/"
        f"{os.environ.get('PGDATABASE','agent1')}"
    )

with psycopg.connect(url, row_factory=dict_row) as conn:
    cur = conn.cursor()

    cur.execute(
        "SELECT column_name FROM information_schema.columns "
        "WHERE table_name='jobs' ORDER BY ordinal_position"
    )
    cols = [r["column_name"] for r in cur.fetchall()]
    print("JOBS_COLS", cols)

    cur.execute("SELECT status, COUNT(*)::int n FROM jobs GROUP BY status ORDER BY n DESC")
    print("JOBS_BY_STATUS", cur.fetchall())

    if "day" in cols:
        cur.execute(
            "SELECT day::text d, status, COUNT(*)::int n FROM jobs "
            "GROUP BY 1,2 ORDER BY 1 DESC, 3 DESC"
        )
        print("JOBS_BY_DAY", cur.fetchall())

    cur.execute(
        "SELECT id::text, day::text d, status, created_at::text, started_at::text, "
        "finished_at::text, note FROM runs ORDER BY created_at DESC LIMIT 8"
    )
    print("RUNS")
    for r in cur.fetchall():
        print("  ", r)

    cur.execute(
        "SELECT day::text d, COUNT(*)::int n, MIN(created_at)::text first_at, "
        "MAX(created_at)::text last_at FROM agent_decisions GROUP BY 1 ORDER BY 1 DESC"
    )
    print("DECISIONS_BY_DAY")
    for r in cur.fetchall():
        print("  ", r)

    for mins in (10, 60, 360, 1440):
        cur.execute(
            "SELECT COUNT(*)::int n FROM agent_decisions "
            "WHERE created_at > now() - (%s || ' minutes')::interval",
            (mins,),
        )
        n = cur.fetchone()["n"]
        print(f"THROUGHPUT_LAST_{mins}MIN", n, "=> per_hour", round(n * 60.0 / mins, 1))

    cur.execute(
        "SELECT COUNT(*)::int n FROM jobs WHERE status='in_progress' "
        "AND started_at < now() - interval '15 minutes'"
    ) if "started_at" in cols else None
    if "started_at" in cols:
        print("STUCK_IN_PROGRESS_GT15MIN", cur.fetchone())
PY

echo "=== worker unit env ==="
systemctl cat agent1-worker | grep -E 'Environment|ExecStart' || true
echo "=== worker processes ==="
pgrep -af 'worker.py' || true
echo "=== vision errors today ==="
journalctl -u agent1-worker --since today --no-pager | grep -ciE '429|rate_limit|timeout|vision_error' || true
echo DONE
