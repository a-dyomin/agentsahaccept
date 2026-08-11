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
day = "2026-08-03"
conn = psycopg.connect(url, row_factory=dict_row)
cur = conn.cursor()

def q(sql, args=()):
    cur.execute(sql, args)
    return cur.fetchall()

rows = q("SELECT itog, COUNT(*)::int n FROM agent_decisions WHERE day=%s::date GROUP BY itog ORDER BY n DESC", (day,))
total = sum(r["n"] for r in rows)
print("=== ИТОГ (обработано %d) ===" % total)
for r in rows:
    print(f"  {r['itog']:<22} {r['n']:5d}  {100.0*r['n']/total:5.1f}%")

print("\n=== stage2 status ===")
for r in q("SELECT COALESCE(stage2->>'status','null') st, COUNT(*)::int n FROM agent_decisions WHERE day=%s::date GROUP BY 1 ORDER BY n DESC", (day,)):
    print(f"  {r['st']:<14} {r['n']}")

print("\n=== причины фото-нарушений (top 20) ===")
pv = q("SELECT za_chto, COUNT(*)::int n FROM agent_decisions WHERE day=%s::date AND itog='НАРУШЕНИЕ (фото)' GROUP BY za_chto ORDER BY n DESC LIMIT 20", (day,))
pv_total = q("SELECT COUNT(*)::int n FROM agent_decisions WHERE day=%s::date AND itog='НАРУШЕНИЕ (фото)'", (day,))[0]["n"]
for r in pv:
    print(f"  {r['n']:5d}  {r['za_chto']}")
print("  ВСЕГО фото-нарушений:", pv_total)

print("\n=== вклад отдельных кодов в фото-нарушения ===")
for code in ("О1","О2","О3","А0","А1","А3","А4","А5","С2","С3","С4","Б2","Б3","Б4","Н1","Н2","Н3","Н5","ГЕО"):
    pat = f"%фото:{code}%" if code != "ГЕО" else "%ГЕО%"
    n = q("SELECT COUNT(*)::int n FROM agent_decisions WHERE day=%s::date AND itog='НАРУШЕНИЕ (фото)' AND za_chto LIKE %s", (day, pat))[0]["n"]
    if n:
        print(f"  {code:<4} {n:5d}  {100.0*n/pv_total:5.1f}% от фото-нарушений")

print("\n=== только ГЕО (без фото-кодов) ===")
print(q("SELECT COUNT(*)::int n FROM agent_decisions WHERE day=%s::date AND itog='НАРУШЕНИЕ (фото)' AND za_chto NOT LIKE '%%фото:%%'", (day,))[0])

print("\n=== по чек-листам ===")
for r in q("SELECT checklist, itog, COUNT(*)::int n FROM agent_decisions WHERE day=%s::date AND checklist IS NOT NULL GROUP BY checklist, itog ORDER BY checklist, n DESC", (day,)):
    print(f"  {r['checklist']:>3}  {r['itog']:<22} {r['n']}")

print("\n=== доля единиц по кодам, чек-лист 1а (vision ok) ===")
r = q("""
 SELECT COUNT(*)::int n,
  SUM((stage2->'answers'->>'О1')::int)::int o1,
  SUM((stage2->'answers'->>'О2')::int)::int o2,
  SUM((stage2->'answers'->>'О3')::int)::int o3_fake,
  SUM((stage2->'answers'->>'А0')::int)::int a0,
  SUM((stage2->'answers'->>'А1')::int)::int a1,
  SUM((stage2->'answers'->>'А2')::int)::int a2,
  SUM((stage2->'answers'->>'А3')::int)::int a3,
  SUM((stage2->'answers'->>'А4')::int)::int a4,
  SUM((stage2->'answers'->>'А5')::int)::int a5
 FROM agent_decisions WHERE day=%s::date AND checklist='1а' AND stage2->>'status'='ok'
   AND stage2->'answers'->>'А2' ~ '^[0-9]+$'
""", (day,))[0]
print(" ", r)

print("\n=== 1а: комбинации А2/А3 ===")
for x in q("""
 SELECT (stage2->'answers'->>'А2') a2, (stage2->'answers'->>'А3') a3, COUNT(*)::int n
 FROM agent_decisions WHERE day=%s::date AND checklist='1а' AND stage2->>'status'='ok'
 GROUP BY 1,2 ORDER BY n DESC LIMIT 8
""", (day,)):
    print("  А2=%s А3=%s -> %d" % (x["a2"], x["a3"], x["n"]))

print("\n=== 1б: С-коды ===")
print(" ", q("""
 SELECT COUNT(*)::int n,
  SUM((stage2->'answers'->>'С1')::int)::int c1,
  SUM((stage2->'answers'->>'С2')::int)::int c2,
  SUM((stage2->'answers'->>'С3')::int)::int c3,
  SUM((stage2->'answers'->>'С4')::int)::int c4
 FROM agent_decisions WHERE day=%s::date AND checklist='1б' AND stage2->>'status'='ok'
   AND stage2->'answers'->>'С1' ~ '^[0-9]+$'
""", (day,))[0])

print("\n=== 1г: Б-коды ===")
print(" ", q("""
 SELECT COUNT(*)::int n,
  SUM((stage2->'answers'->>'Б1')::int)::int b1,
  SUM((stage2->'answers'->>'Б2')::int)::int b2,
  SUM((stage2->'answers'->>'Б3')::int)::int b3,
  SUM((stage2->'answers'->>'Б4')::int)::int b4,
  SUM((stage2->'answers'->>'Б5')::int)::int b5
 FROM agent_decisions WHERE day=%s::date AND checklist='1г' AND stage2->>'status'='ok'
   AND stage2->'answers'->>'Б1' ~ '^[0-9]+$'
""", (day,))[0])

print("\n=== 2 (невывоз): Н-коды ===")
print(" ", q("""
 SELECT COUNT(*)::int n,
  SUM((stage2->'answers'->>'Н1')::int)::int h1,
  SUM((stage2->'answers'->>'Н2')::int)::int h2,
  SUM((stage2->'answers'->>'Н3')::int)::int h3,
  SUM((stage2->'answers'->>'Н5')::int)::int h5
 FROM agent_decisions WHERE day=%s::date AND checklist='2' AND stage2->>'status'='ok'
   AND stage2->'answers'->>'Н1' ~ '^[0-9]+$'
""", (day,))[0])

print("\n=== примеры: фото:А3 ===")
for r in q("""
 SELECT order_id, left(COALESCE(stage2->>'comment',''),110) c
 FROM agent_decisions WHERE day=%s::date AND za_chto LIKE '%%фото:А3%%' ORDER BY random() LIMIT 8
""", (day,)):
    print(f"  {r['order_id']} {r['c']}")

print("\n=== примеры: фото:О1 ===")
for r in q("""
 SELECT order_id, checklist, left(COALESCE(stage2->>'comment',''),110) c
 FROM agent_decisions WHERE day=%s::date AND za_chto LIKE '%%фото:О1%%' ORDER BY random() LIMIT 8
""", (day,)):
    print(f"  {r['order_id']} {r['checklist']} {r['c']}")

print("\n=== примеры: фото:А4 ===")
for r in q("""
 SELECT order_id, left(COALESCE(stage2->>'comment',''),110) c
 FROM agent_decisions WHERE day=%s::date AND za_chto LIKE '%%фото:А4%%' ORDER BY random() LIMIT 6
""", (day,)):
    print(f"  {r['order_id']} {r['c']}")

print("\n=== сверка с человеком ===")
print(" ", q("""
 SELECT COUNT(*)::int compared,
   COUNT(*) FILTER (WHERE match_flag=1)::int agreed,
   COUNT(*) FILTER (WHERE match_flag=0)::int disagreed
 FROM comparisons WHERE day=%s::date AND match_flag IS NOT NULL
""", (day,))[0])
for r in q("""
 SELECT agent_itog, human_breach_state, COUNT(*)::int n
 FROM comparisons WHERE day=%s::date AND match_flag IS NOT NULL
 GROUP BY 1,2 ORDER BY n DESC LIMIT 10
""", (day,)):
    print(f"  {r['agent_itog']:<22} human={r['human_breach_state']:<10} {r['n']}")

print("\n=== стоимость ===")
print(" ", q("SELECT COUNT(*)::int calls, ROUND(COALESCE(SUM(cost_usd),0)::numeric,3) usd FROM vision_usage WHERE day=%s::date", (day,))[0])
conn.close()
PY
