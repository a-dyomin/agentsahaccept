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
with psycopg.connect(url, row_factory=dict_row) as conn:
    cur = conn.cursor()
    cur.execute(
        "SELECT itog, COUNT(*)::int n FROM agent_decisions WHERE day=%s::date GROUP BY itog ORDER BY n DESC",
        (day,),
    )
    rows = cur.fetchall()
    total = sum(r["n"] for r in rows)
    print("ОБРАБОТАНО", total)
    for r in rows:
        pct = 100.0 * r["n"] / total if total else 0
        print(f"  {r['itog']:<22} {r['n']:5d}  {pct:5.1f}%")

    print("\nПРИЧИНЫ фото-нарушений:")
    cur.execute(
        "SELECT za_chto, COUNT(*)::int n FROM agent_decisions "
        "WHERE day=%s::date AND itog='НАРУШЕНИЕ (фото)' GROUP BY za_chto ORDER BY n DESC LIMIT 12",
        (day,),
    )
    for r in cur.fetchall():
        print(f"  {r['n']:5d}  {r['za_chto']}")

    cur.execute(
        "SELECT COUNT(*)::int n FROM agent_decisions WHERE day=%s::date AND stage2->'answers'->>'О3'='1'",
        (day,),
    )
    print("\nО3=подделка (внутр.):", cur.fetchone()["n"])
    cur.execute(
        "SELECT COUNT(*)::int n FROM agent_decisions WHERE day=%s::date AND stage2->>'status'='ok'",
        (day,),
    )
    print("vision ok:", cur.fetchone()["n"])
    cur.execute(
        """
        SELECT COUNT(*)::int n,
          SUM((stage2->'answers'->>'А2')::int)::int a2,
          SUM((stage2->'answers'->>'А3')::int)::int a3,
          SUM((stage2->'answers'->>'А5')::int)::int a5
        FROM agent_decisions
        WHERE day=%s::date AND checklist='1а' AND stage2->>'status'='ok'
          AND stage2->'answers'->>'А2' ~ '^[0-9]+$'
        """,
        (day,),
    )
    print("1а коды (n, А2=1, А3=1, А5=1):", cur.fetchone())
    cur.execute(
        "SELECT COUNT(*)::int n, ROUND(COALESCE(SUM(cost_usd),0)::numeric,3) c FROM vision_usage WHERE day=%s::date",
        (day,),
    )
    print("vision_usage:", cur.fetchone())
PY
