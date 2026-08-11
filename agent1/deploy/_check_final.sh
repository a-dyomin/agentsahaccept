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

cur.execute("SELECT COUNT(*)::int n FROM agent_decisions WHERE day=%s::date", (day,))
tot = cur.fetchone()["n"]
print(f"обработано: {tot}")
if not tot:
    raise SystemExit(0)

print("\n=== ИТОГ ===")
cur.execute(
    "SELECT itog, COUNT(*)::int n FROM agent_decisions WHERE day=%s::date "
    "GROUP BY itog ORDER BY n DESC",
    (day,),
)
for r in cur.fetchall():
    print(f"  {r['itog']:<22} {r['n']:5d}  {100.0*r['n']/tot:5.1f}%")

cur.execute(
    "SELECT COUNT(*)::int n FROM agent_decisions WHERE day=%s::date AND itog='НАРУШЕНИЕ (фото)'",
    (day,),
)
pv = cur.fetchone()["n"]
print(f"\nфото-нарушений: {pv}")
if pv:
    cur.execute(
        "SELECT COUNT(*)::int n FROM agent_decisions WHERE day=%s::date "
        "AND itog='НАРУШЕНИЕ (фото)' AND za_chto LIKE '%%фото:%%'",
        (day,),
    )
    print("  по содержанию:", cur.fetchone()["n"])
    cur.execute(
        "SELECT COUNT(*)::int n FROM agent_decisions WHERE day=%s::date "
        "AND itog='НАРУШЕНИЕ (фото)' AND za_chto NOT LIKE '%%фото:%%'",
        (day,),
    )
    print("  только ГЕО/трек:", cur.fetchone()["n"])
    print("  вклад кодов:")
    for code in ("О1", "О3", "А3", "А4", "С2", "Б2", "Б3", "Б4", "Н5"):
        cur.execute(
            "SELECT COUNT(*)::int n FROM agent_decisions WHERE day=%s::date "
            "AND itog='НАРУШЕНИЕ (фото)' AND za_chto LIKE %s",
            (day, f"%фото:{code}%"),
        )
        n = cur.fetchone()["n"]
        if n:
            print(f"    {code:<3} {n:5d}  {100.0*n/pv:5.1f}%")

print("\n=== 1а А2/А3 ===")
cur.execute(
    "SELECT (stage2->'answers'->>'А2') a2, (stage2->'answers'->>'А3') a3, COUNT(*)::int n "
    "FROM agent_decisions WHERE day=%s::date AND checklist='1а' AND stage2->>'status'='ok' "
    "GROUP BY 1,2 ORDER BY n DESC",
    (day,),
)
rows = cur.fetchall()
s = sum(r["n"] for r in rows) or 1
for r in rows:
    print(f"  А2={r['a2']} А3={r['a3']} -> {r['n']:5d}  {100.0*r['n']/s:5.1f}%")
a3 = sum(r["n"] for r in rows if r["a3"] == "1")
print(f"  А3=1: {a3}/{s} ({100.0*a3/s:.1f}%)  [было 0.4% до пометок]")

print("\n=== О3: модель / смягчение / внутренний ===")
cur.execute(
    """
    SELECT COUNT(*)::int n,
      COUNT(*) FILTER (WHERE stage2->'answers_model'->>'О3'='0')::int model_fake,
      COUNT(*) FILTER (WHERE (stage2->>'o3_softened')::boolean IS TRUE)::int softened,
      COUNT(*) FILTER (WHERE stage2->'answers'->>'О3'='1')::int int_fake
    FROM agent_decisions
    WHERE day=%s::date AND checklist='1а' AND stage2->>'status'='ok'
    """,
    (day,),
)
print(" ", cur.fetchone())

print("\n=== стоимость ===")
cur.execute(
    "SELECT COUNT(*)::int calls, ROUND(COALESCE(SUM(cost_usd),0)::numeric,3) usd "
    "FROM vision_usage WHERE day=%s::date",
    (day,),
)
print(" ", cur.fetchone())
conn.close()
PY
