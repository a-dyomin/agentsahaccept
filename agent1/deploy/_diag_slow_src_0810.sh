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

with psycopg.connect(url, row_factory=dict_row) as conn:
    cur = conn.cursor()

    cur.execute(
        "SELECT column_name FROM information_schema.columns "
        "WHERE table_name='vision_usage' ORDER BY ordinal_position"
    )
    print("VISION_USAGE_COLS", [r["column_name"] for r in cur.fetchall()])

    cur.execute(
        """
        SELECT to_char(date_trunc('hour', created_at), 'MM-DD HH24') h, COUNT(*)::int n
        FROM vision_usage WHERE created_at > now() - interval '72 hours'
        GROUP BY 1 ORDER BY 1
        """
    )
    print("VISION_CALLS_PER_HOUR_72H")
    for r in cur.fetchall():
        print(f"   {r['h']}  {r['n']:5d}")

    # decisions during the slow window vs now: stage2 status mix
    cur.execute(
        """
        SELECT CASE WHEN created_at < '2026-08-10 03:00+00' THEN 'slow_window' ELSE 'after_recovery' END w,
               COALESCE(stage2->>'status','none') st, COUNT(*)::int n
        FROM agent_decisions
        WHERE created_at > now() - interval '48 hours'
        GROUP BY 1,2 ORDER BY 1, 3 DESC
        """
    )
    print("S2_STATUS_SLOW_VS_FAST")
    for r in cur.fetchall():
        print("  ", r)
PY

echo "=== photo host reachability / latency ==="
for i in 1 2 3; do
  curl -sk --noproxy '*' -o /dev/null -w "attempt$i http_code=%{http_code} connect=%{time_connect}s total=%{time_total}s\n" \
    -m 30 "https://192.168.80.80/" || echo "attempt$i FAILED"
done

echo "=== S3/photo env (names only) ==="
grep -oE '^[A-Z0-9_]+' /home/admin-akea/agent1/.env | grep -iE 's3|photo|vision|greta' || true

echo "=== vision endpoint latency test ==="
grep -oE '^AGENT1_VISION_URL=.*' /home/admin-akea/agent1/.env | sed 's#\(https\?://[^/]*\).*#\1 (host only)#' || true

echo DONE
