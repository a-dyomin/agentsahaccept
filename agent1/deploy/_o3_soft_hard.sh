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

url = next(
    os.environ[k]
    for k in ("DATABASE_URL", "AGENT1_DATABASE_URL", "AGENT1_DB_URL")
    if os.environ.get(k)
)
day = "2026-08-03"
conn = psycopg.connect(url, row_factory=dict_row)
cur = conn.cursor()

cur.execute(
    """
    SELECT COUNT(*)::int n,
      COUNT(*) FILTER (WHERE comment ~* 'скрин|карт|экран|дубл')::int hard,
      COUNT(*) FILTER (WHERE comment ~* 'соответств' AND comment !~* 'скрин|карт|экран')::int soft
    FROM (
      SELECT lower(COALESCE(stage2->>'comment','')) comment
      FROM agent_decisions
      WHERE day=%s::date AND checklist='1а'
        AND stage2->'answers_model'->>'О3'='0'
    ) t
    """,
    (day,),
)
print("О3=0 у модели в 1а:", cur.fetchone())

print("\nкомментарии (частотные шаблоны):")
cur.execute(
    """
    SELECT left(COALESCE(stage2->>'comment',''),90) c, COUNT(*)::int n
    FROM agent_decisions
    WHERE day=%s::date AND checklist='1а' AND stage2->'answers_model'->>'О3'='0'
    GROUP BY 1 ORDER BY n DESC LIMIT 10
    """,
    (day,),
)
for r in cur.fetchall():
    print(f"  {r['n']:3d}  {r['c']}")

print("\nпрогресс дня:")
cur.execute(
    "SELECT COUNT(*)::int n FROM agent_decisions WHERE day=%s::date", (day,)
)
print(" ", cur.fetchone())
cur.execute(
    "SELECT itog, COUNT(*)::int n FROM agent_decisions WHERE day=%s::date "
    "GROUP BY itog ORDER BY n DESC",
    (day,),
)
for r in cur.fetchall():
    print(f"  {r['itog']:<22} {r['n']}")
conn.close()
PY
