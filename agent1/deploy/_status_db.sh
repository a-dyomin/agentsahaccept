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

day = "2026-08-03"
with psycopg.connect(url, row_factory=dict_row) as conn:
    cur = conn.cursor()
    cur.execute("SELECT status, COUNT(*)::int n FROM jobs GROUP BY status ORDER BY n DESC")
    print("JOBS", cur.fetchall())
    cur.execute(
        "SELECT itog, COUNT(*)::int n FROM agent_decisions WHERE day=%s::date GROUP BY itog ORDER BY n DESC",
        (day,),
    )
    print("ITOG_03", cur.fetchall())
    cur.execute(
        "SELECT COALESCE(stage2->>'status','null') st, COUNT(*)::int n "
        "FROM agent_decisions WHERE day=%s::date GROUP BY 1 ORDER BY n DESC",
        (day,),
    )
    print("S2_03", cur.fetchall())
    cur.execute(
        """
        SELECT COUNT(*)::int n FROM agent_decisions
        WHERE day=%s::date AND (
          pometki ILIKE '%%429%%'
          OR COALESCE(stage2->>'reason','') ILIKE '%%429%%'
          OR COALESCE(stage2->>'status','') = 'vision_error'
        )
        """,
        (day,),
    )
    print("HIT_429_OR_VISION_ERR", cur.fetchone())
    cur.execute(
        "SELECT COUNT(*)::int n FROM agent_decisions WHERE day=%s::date AND COALESCE(stage2->>'status','')='ok'",
        (day,),
    )
    print("VISION_OK_03", cur.fetchone())
    cur.execute(
        "SELECT COUNT(*)::int n, ROUND(COALESCE(SUM(cost_usd),0)::numeric,4) c FROM vision_usage WHERE day=%s::date",
        (day,),
    )
    print("USAGE_03", cur.fetchone())
    cur.execute("SELECT COUNT(*)::int n FROM jobs WHERE status='queued'")
    print("QUEUED", cur.fetchone())
PY

echo "---429 today---"
journalctl -u agent1-worker --since "today" --no-pager | grep -c 'vision 429' || true
echo "---interesting lines---"
journalctl -u agent1-worker --since "today" --no-pager | grep -iE 'insufficient|quota|billing|rate_limit|Client error|401|403|payment|credit' | tail -40 || true
echo "---tail---"
journalctl -u agent1-worker -n 15 --no-pager
echo DONE
