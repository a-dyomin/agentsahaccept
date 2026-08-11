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

url = next(os.environ[k] for k in ("DATABASE_URL","AGENT1_DATABASE_URL","AGENT1_DB_URL") if os.environ.get(k))
day = "2026-08-04"
conn = psycopg.connect(url, row_factory=dict_row)
cur = conn.cursor()

print("=== К ЧЕЛОВЕКУ + 'место не проверено': ГЕО/ТРЕК ===")
cur.execute("""
 SELECT stage1->>'ГЕО' g,
        stage1->>'ГЕО_БЕЗ_КООРД' nc,
        stage1->>'ТРЕК' t,
        stage1->>'ТРЕК_ЕСТЬ' te,
        stage2->>'photo_verdict' pv,
        COUNT(*)::int n
 FROM agent_decisions
 WHERE day=%s::date AND itog='К ЧЕЛОВЕКУ' AND pometki ILIKE '%%место не проверено%%'
 GROUP BY 1,2,3,4,5 ORDER BY n DESC
""", (day,))
for r in cur.fetchall():
    print(f"  n={r['n']:4d} ГЕО={r['g']} без_коорд={r['nc']} ТРЕК={r['t']} есть={r['te']} photo={r['pv']}")

print("\n=== сколько из них спасли бы правилом ТРЕК=1 + ПОДТВЕРЖДЕНО ===")
cur.execute("""
 SELECT COUNT(*)::int n
 FROM agent_decisions
 WHERE day=%s::date AND itog='К ЧЕЛОВЕКУ'
   AND pometki ILIKE '%%место не проверено%%'
   AND stage1->>'ТРЕК'='1'
   AND stage2->>'photo_verdict'='ПОДТВЕРЖДЕНО'
""", (day,))
print(" ", cur.fetchone())

print("\n=== очередь: сколько ещё created / done впереди ===")
cur.execute("""
 SELECT COALESCE(o.state,'?') st, COUNT(*)::int n
 FROM jobs j
 JOIN runs r ON r.id=j.run_id
 JOIN orders_day o ON o.day=r.day::date AND o.order_id = (j.payload->>'order_id')::bigint
 WHERE r.day=%s AND j.status='queued'
 GROUP BY 1 ORDER BY n DESC LIMIT 10
""", (day,))
# payload may store order_id differently - try simpler
try:
    rows = cur.fetchall()
    for r in rows:
        print(f"  queued state={r['st']}: {r['n']}")
except Exception as e:
    conn.rollback()
    print(" payload join failed:", e)

cur.execute("""
 SELECT status, COUNT(*)::int n FROM jobs j
 JOIN runs r ON r.id=j.run_id WHERE r.day=%s GROUP BY 1
""", (day,))
print("jobs:", cur.fetchall())

# remaining not_in_work estimate from orders not yet decided
cur.execute("""
 SELECT COUNT(*)::int left_created
 FROM orders_day o
 WHERE o.day=%s::date AND o.state='created'
   AND NOT EXISTS (
     SELECT 1 FROM agent_decisions d WHERE d.day=o.day AND d.order_id=o.order_id
   )
""", (day,))
print("ещё не решённые created:", cur.fetchone())

cur.execute("""
 SELECT COUNT(*)::int left_done
 FROM orders_day o
 WHERE o.day=%s::date AND o.state IN ('done','retry')
   AND NOT EXISTS (
     SELECT 1 FROM agent_decisions d WHERE d.day=o.day AND d.order_id=o.order_id
   )
""", (day,))
print("ещё не решённые done/retry:", cur.fetchone())
conn.close()
PY
