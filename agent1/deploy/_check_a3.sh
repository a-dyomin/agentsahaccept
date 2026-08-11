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


tot = q("SELECT COUNT(*)::int n FROM agent_decisions WHERE day=%s::date", (day,))[0]["n"]
print(f"обработано: {tot}")
print("\n=== ИТОГ ===")
for r in q(
    "SELECT itog, COUNT(*)::int n FROM agent_decisions WHERE day=%s::date "
    "GROUP BY itog ORDER BY n DESC",
    (day,),
):
    print(f"  {r['itog']:<22} {r['n']:5d}  {100.0*r['n']/tot:5.1f}%")

pv = q(
    "SELECT COUNT(*)::int n FROM agent_decisions WHERE day=%s::date "
    "AND itog='НАРУШЕНИЕ (фото)'",
    (day,),
)[0]["n"]
print(f"\nфото-нарушений: {pv}")
if pv:
    print("  из них по содержанию кадров:",
          q("SELECT COUNT(*)::int n FROM agent_decisions WHERE day=%s::date "
            "AND itog='НАРУШЕНИЕ (фото)' AND za_chto LIKE '%%фото:%%'", (day,))[0]["n"])
    print("  из них только ГЕО/трек:    ",
          q("SELECT COUNT(*)::int n FROM agent_decisions WHERE day=%s::date "
            "AND itog='НАРУШЕНИЕ (фото)' AND za_chto NOT LIKE '%%фото:%%'", (day,))[0]["n"])
    print("\n  вклад кодов:")
    for code in ("О1", "О3", "А1", "А3", "А4", "А5", "С2", "Б2", "Б3", "Б4", "Н5"):
        n = q(
            "SELECT COUNT(*)::int n FROM agent_decisions WHERE day=%s::date "
            "AND itog='НАРУШЕНИЕ (фото)' AND za_chto LIKE %s",
            (day, f"%фото:{code}%"),
        )[0]["n"]
        if n:
            print(f"    {code:<3} {n:5d}  {100.0*n/pv:5.1f}%")

print("\n=== 1а: А2/А3 у модели ===")
rows = q(
    "SELECT (stage2->'answers'->>'А2') a2, (stage2->'answers'->>'А3') a3, COUNT(*)::int n "
    "FROM agent_decisions WHERE day=%s::date AND checklist='1а' AND stage2->>'status'='ok' "
    "GROUP BY 1,2 ORDER BY n DESC",
    (day,),
)
s = sum(r["n"] for r in rows) or 1
for r in rows:
    print(f"  А2={r['a2']} А3={r['a3']} -> {r['n']:5d}  {100.0*r['n']/s:5.1f}%")
a3_ones = sum(r["n"] for r in rows if r["a3"] == "1")
print(f"  А3=1: {a3_ones} из {s} ({100.0*a3_ones/s:.1f}%)   [было 3 из 790 = 0.4%]")

print("\n=== 1г: Б2 у модели ===")
print(" ", q(
    "SELECT COUNT(*)::int n, SUM((stage2->'answers'->>'Б1')::int)::int b1, "
    "SUM((stage2->'answers'->>'Б2')::int)::int b2 "
    "FROM agent_decisions WHERE day=%s::date AND checklist='1г' AND stage2->>'status'='ok' "
    "AND stage2->'answers'->>'Б1' ~ '^[0-9]+$'",
    (day,),
)[0])

print("\n=== 1б: С1/С2 у модели ===")
print(" ", q(
    "SELECT COUNT(*)::int n, SUM((stage2->'answers'->>'С1')::int)::int c1, "
    "SUM((stage2->'answers'->>'С2')::int)::int c2 "
    "FROM agent_decisions WHERE day=%s::date AND checklist='1б' AND stage2->>'status'='ok' "
    "AND stage2->'answers'->>'С1' ~ '^[0-9]+$'",
    (day,),
)[0])

print("\n=== А4/Н5 после смены полярности (внутренние 1 = нарушение) ===")
print("  А4=1:", q(
    "SELECT COUNT(*)::int n FROM agent_decisions WHERE day=%s::date "
    "AND stage2->'answers'->>'А4'='1'", (day,))[0]["n"])
print("  Н5=1:", q(
    "SELECT COUNT(*)::int n FROM agent_decisions WHERE day=%s::date "
    "AND stage2->'answers'->>'Н5'='1'", (day,))[0]["n"])

print("\n=== стоимость ===")
print(" ", q(
    "SELECT COUNT(*)::int calls, ROUND(COALESCE(SUM(cost_usd),0)::numeric,3) usd "
    "FROM vision_usage WHERE day=%s::date", (day,))[0])
conn.close()
PY
