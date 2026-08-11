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
day = "2026-08-04"
conn = psycopg.connect(url, row_factory=dict_row)
cur = conn.cursor()

def q(sql, args=()):
    cur.execute(sql, args)
    return cur.fetchall()

print("=== прогресс jobs ===")
print(q(
    "SELECT j.status, COUNT(*)::int n FROM jobs j "
    "JOIN runs r ON r.id=j.run_id WHERE r.day=%s GROUP BY j.status ORDER BY n DESC",
    (day,),
))

tot = q("SELECT COUNT(*)::int n FROM agent_decisions WHERE day=%s::date", (day,))[0]["n"]
print(f"\nрешений: {tot}")

print("\n=== ИТОГ ===")
rows = q(
    "SELECT itog, COUNT(*)::int n FROM agent_decisions WHERE day=%s::date "
    "GROUP BY itog ORDER BY n DESC", (day,)
)
for r in rows:
    print(f"  {r['itog']:<22} {r['n']:5d}  {100.0*r['n']/max(tot,1):5.1f}%")

auto = sum(r["n"] for r in rows if r["itog"] == "ЧИСТО" or str(r["itog"]).startswith("НАРУШЕНИЕ"))
human = next((r["n"] for r in rows if r["itog"] == "К ЧЕЛОВЕКУ"), 0)
niw = next((r["n"] for r in rows if r["itog"] == "НЕ ВЗЯТА В РАБОТУ"), 0)
scope = auto + human
print(f"\nпроизводительность: {100.0*auto/scope if scope else 0:.1f}%  (auto={auto}, human={human})")
print(f"НЕ ВЗЯТА В РАБОТУ: {niw} ({100.0*niw/max(tot,1):.1f}% от всех решений) — вне охвата, не в KPI")

print("\n=== НЕ ВЗЯТА В РАБОТУ: причины (state / schedule) ===")
for r in q(
    """
    SELECT COALESCE(o.state,'(null)') st,
           CASE WHEN o.schedule_id IS NULL OR o.schedule_id=0 THEN 'no_schedule' ELSE 'has_schedule' END sch,
           COUNT(*)::int n
    FROM agent_decisions d
    LEFT JOIN orders_day o ON o.day=d.day AND o.order_id=d.order_id
    WHERE d.day=%s::date AND d.itog='НЕ ВЗЯТА В РАБОТУ'
    GROUP BY 1,2 ORDER BY n DESC
    """,
    (day,),
):
    print(f"  {r['n']:5d}  state={r['st']:<28} {r['sch']}")

print("\n=== НЕ ВЗЯТА: za_chto / pometki ===")
for r in q(
    """
    SELECT COALESCE(za_chto,'(пусто)') z, COALESCE(left(pometki,60),'(пусто)') p, COUNT(*)::int n
    FROM agent_decisions WHERE day=%s::date AND itog='НЕ ВЗЯТА В РАБОТУ'
    GROUP BY 1,2 ORDER BY n DESC LIMIT 10
    """,
    (day,),
):
    print(f"  {r['n']:5d}  za={r['z']}  p={r['p']}")

print("\n=== К ЧЕЛОВЕКУ: причины (pometki / stage2) ===")
for r in q(
    """
    SELECT left(COALESCE(pometki,''),90) p,
           COALESCE(stage2->>'status','null') st,
           COALESCE(stage2->>'reason','') reason,
           COUNT(*)::int n
    FROM agent_decisions WHERE day=%s::date AND itog='К ЧЕЛОВЕКУ'
    GROUP BY 1,2,3 ORDER BY n DESC LIMIT 20
    """,
    (day,),
):
    print(f"  {r['n']:5d}  s2={r['st']:<12} reason={r['reason'][:40]:<40} {r['p']}")

print("\n=== К ЧЕЛОВЕКУ: state / checklist ===")
for r in q(
    """
    SELECT COALESCE(o.state,'?') st, COALESCE(d.checklist,'(нет)') cl, COUNT(*)::int n
    FROM agent_decisions d
    LEFT JOIN orders_day o ON o.day=d.day AND o.order_id=d.order_id
    WHERE d.day=%s::date AND d.itog='К ЧЕЛОВЕКУ'
    GROUP BY 1,2 ORDER BY n DESC LIMIT 15
    """,
    (day,),
):
    print(f"  {r['n']:5d}  {r['st']:<22} {r['cl']}")

print("\n=== динамика: первые/последние 500 по created_at ===")
for label, order in (("первые 500", "ASC"), ("последние 500", "DESC")):
    cur.execute(
        f"""
        WITH t AS (
          SELECT itog FROM agent_decisions WHERE day=%s::date
          ORDER BY created_at {order} LIMIT 500
        )
        SELECT itog, COUNT(*)::int n FROM t GROUP BY itog ORDER BY n DESC
        """,
        (day,),
    )
    print(f"  --- {label} ---")
    for r in cur.fetchall():
        print(f"    {r['itog']:<22} {r['n']}")

print("\n=== ГЕО_ПО_ТРЕКУ (новый fallback) ===")
print(" ", q(
    "SELECT COUNT(*)::int n FROM agent_decisions WHERE day=%s::date AND stage1->>'ГЕО_ПО_ТРЕКУ'='1'",
    (day,),
)[0])

print("\n=== ещё ГЕО среди нарушений ===")
print(" ", q(
    """
    SELECT COUNT(*) FILTER (WHERE za_chto ILIKE '%%ГЕО%%')::int with_geo,
           COUNT(*) FILTER (WHERE za_chto='ГЕО')::int only_geo,
           COUNT(*)::int photo_viol
    FROM agent_decisions WHERE day=%s::date AND itog='НАРУШЕНИЕ (фото)'
    """,
    (day,),
)[0])

# compare share of not_in_work in orders_day raw vs decisions
print("\n=== охват в исходной выгрузке orders_day ===")
print(" ", q(
    """
    SELECT COUNT(*)::int orders,
      COUNT(*) FILTER (WHERE schedule_id IS NULL OR schedule_id=0)::int no_sch,
      COUNT(*) FILTER (WHERE state='created')::int created,
      COUNT(*) FILTER (WHERE state='canceled_by_dispatcher')::int disp_cancel,
      COUNT(*) FILTER (WHERE state IN ('done','retry'))::int done_like,
      COUNT(*) FILTER (WHERE state='canceled_by_driver')::int driver_cancel
    FROM orders_day WHERE day=%s::date
    """,
    (day,),
)[0])

conn.close()
PY
