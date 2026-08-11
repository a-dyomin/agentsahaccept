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


def q(sql, args=()):
    cur.execute(sql, args)
    return cur.fetchall()


print("=== О3 (внутренний 1 = подделка) по чек-листам ===")
for r in q(
    "SELECT checklist, COUNT(*)::int n, "
    "COUNT(*) FILTER (WHERE stage2->'answers'->>'О3'='1')::int fake "
    "FROM agent_decisions WHERE day=%s::date AND stage2->>'status'='ok' "
    "GROUP BY checklist ORDER BY checklist",
    (day,),
):
    share = 100.0 * r["fake"] / r["n"] if r["n"] else 0
    print(f"  {r['checklist']:>3}  всего {r['n']:4d}  О3=подделка {r['fake']:4d}  {share:5.1f}%")

print("\n=== О1 (нет пригодных кадров) по чек-листам ===")
for r in q(
    "SELECT checklist, COUNT(*)::int n, "
    "COUNT(*) FILTER (WHERE stage2->'answers'->>'О1'='0')::int bad "
    "FROM agent_decisions WHERE day=%s::date AND stage2->>'status'='ok' "
    "GROUP BY checklist ORDER BY checklist",
    (day,),
):
    share = 100.0 * r["bad"] / r["n"] if r["n"] else 0
    print(f"  {r['checklist']:>3}  всего {r['n']:4d}  О1=0 {r['bad']:4d}  {share:5.1f}%")

print("\n=== примеры О3=подделка: что пишет модель ===")
for r in q(
    "SELECT order_id, checklist, left(COALESCE(stage2->>'comment',''),120) c "
    "FROM agent_decisions WHERE day=%s::date AND stage2->'answers'->>'О3'='1' "
    "ORDER BY random() LIMIT 12",
    (day,),
):
    print(f"  {r['order_id']} {r['checklist']:>3} {r['c']}")

print("\n=== сколько кадров у заявок с О3=подделка ===")
for r in q(
    "SELECT k, COUNT(*)::int orders FROM ("
    "  SELECT d.order_id, COUNT(p.photo_id)::int k"
    "  FROM agent_decisions d LEFT JOIN photos_day p"
    "    ON p.day=d.day AND p.order_id=d.order_id"
    "  WHERE d.day=%s::date AND d.stage2->'answers'->>'О3'='1'"
    "  GROUP BY d.order_id) t GROUP BY k ORDER BY k",
    (day,),
):
    print(f"  {r['k']} фото -> {r['orders']} заявок")

print("\n=== примеры О1=0 ===")
for r in q(
    "SELECT order_id, checklist, left(COALESCE(stage2->>'comment',''),120) c "
    "FROM agent_decisions WHERE day=%s::date AND stage2->'answers'->>'О1'='0' "
    "ORDER BY random() LIMIT 8",
    (day,),
):
    print(f"  {r['order_id']} {r['checklist']:>3} {r['c']}")
conn.close()
PY
