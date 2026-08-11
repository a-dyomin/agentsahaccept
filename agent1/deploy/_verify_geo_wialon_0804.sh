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
with psycopg.connect(url, row_factory=dict_row) as conn:
    cur = conn.cursor()
    cur.execute(
        "SELECT COUNT(*)::int n FROM agent_decisions WHERE day=%s::date",
        (day,),
    )
    total = cur.fetchone()["n"]
    cur.execute(
        """
        SELECT COUNT(*)::int n
        FROM agent_decisions
        WHERE day=%s::date AND stage1->>'ГЕО_ПО_ТРЕКУ'='1'
        """,
        (day,),
    )
    overridden = cur.fetchone()["n"]
    cur.execute(
        """
        SELECT COUNT(*)::int n
        FROM agent_decisions
        WHERE day=%s::date AND za_chto ILIKE '%%ГЕО%%'
        """,
        (day,),
    )
    still_geo = cur.fetchone()["n"]
    cur.execute(
        """
        SELECT order_id, itog, za_chto,
               stage1->>'ГЕО_МИН_М' photo_m,
               stage1->>'ТРЕК_М' track_m,
               pometki
        FROM agent_decisions
        WHERE day=%s::date AND stage1->>'ГЕО_ПО_ТРЕКУ'='1'
        ORDER BY created_at DESC LIMIT 5
        """,
        (day,),
    )
    examples = cur.fetchall()

print("processed:", total)
print("geo_overridden_by_wialon:", overridden)
print("still_geo:", still_geo)
for row in examples:
    print(
        row["order_id"],
        row["itog"],
        "photo_m=", row["photo_m"],
        "track_m=", row["track_m"],
        "za=", row["za_chto"],
        "note=", row["pometki"],
    )
PY
