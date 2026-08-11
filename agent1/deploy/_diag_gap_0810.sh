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
        """
        SELECT to_char(date_trunc('hour', created_at), 'MM-DD HH24:MI') h, COUNT(*)::int n
        FROM agent_decisions
        WHERE created_at > now() - interval '48 hours'
        GROUP BY 1 ORDER BY 1
        """
    )
    print("DECISIONS_PER_HOUR_48H")
    for r in cur.fetchall():
        print(f"   {r['h']}  {r['n']:5d}  {'#' * min(60, r['n'] // 20)}")

    cur.execute(
        """
        SELECT COALESCE(stage2->>'status','none') st, COUNT(*)::int n
        FROM agent_decisions WHERE day='2026-08-07'::date
        GROUP BY 1 ORDER BY 2 DESC
        """
    )
    print("S2_STATUS_0807", cur.fetchall())

    cur.execute("SELECT id::text, order_id, status, created_at::text, leased_at::text, error FROM jobs WHERE status IN ('leased','error') LIMIT 10")
    print("LEASED_OR_ERROR")
    for r in cur.fetchall():
        print("  ", r)
PY

echo "=== gap window: worker log 2026-08-09 12:00 .. 2026-08-10 06:10 (non-routine lines) ==="
journalctl -u agent1-worker --since "2026-08-09 12:00" --until "2026-08-10 06:10" --no-pager \
  | grep -v 'InsecureRequestWarning\|warnings.warn\|urllib3' \
  | grep -viE '^\s*$' | grep -viE 'done order=' | tail -60 || true

echo "=== counts of log lines in gap ==="
journalctl -u agent1-worker --since "2026-08-09 12:00" --until "2026-08-10 06:10" --no-pager | grep -c 'done order=' || true

echo "=== error/429 samples today ==="
journalctl -u agent1-worker --since today --no-pager | grep -iE '429|rate_limit|timeout|vision_error|poll error|error order' | tail -25 || true
echo DONE
