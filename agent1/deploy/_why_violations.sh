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
    print("ITOG", cur.fetchall())

    cur.execute(
        "SELECT COALESCE(stage2->>'status','null') st, COUNT(*)::int n "
        "FROM agent_decisions WHERE day=%s::date GROUP BY 1 ORDER BY n DESC",
        (day,),
    )
    print("STAGE2_STATUS", cur.fetchall())

    print("\n=== ЗА ЧТО (все) ===")
    cur.execute(
        "SELECT za_chto, COUNT(*)::int n FROM agent_decisions "
        "WHERE day=%s::date AND COALESCE(za_chto,'')<>'' GROUP BY za_chto ORDER BY n DESC LIMIT 25",
        (day,),
    )
    for r in cur.fetchall():
        print(f"{r['n']:6d}  {r['za_chto']}")

    print("\n=== ЗА ЧТО только фото-нарушения ===")
    cur.execute(
        "SELECT za_chto, COUNT(*)::int n FROM agent_decisions "
        "WHERE day=%s::date AND itog='НАРУШЕНИЕ (фото)' GROUP BY za_chto ORDER BY n DESC LIMIT 25",
        (day,),
    )
    for r in cur.fetchall():
        print(f"{r['n']:6d}  {r['za_chto']}")

    print("\n=== по чек-листам: итог ===")
    cur.execute(
        "SELECT checklist, itog, COUNT(*)::int n FROM agent_decisions "
        "WHERE day=%s::date AND checklist IS NOT NULL GROUP BY checklist, itog ORDER BY checklist, n DESC",
        (day,),
    )
    for r in cur.fetchall():
        print(f"{r['checklist']:>4}  {r['itog']:<22} {r['n']}")

    print("\n=== ГЕО-провал среди фото-нарушений ===")
    cur.execute(
        """
        SELECT
          COUNT(*) FILTER (WHERE COALESCE(stage1->>'ГЕО','')='0')::int geo_fail,
          COUNT(*) FILTER (WHERE COALESCE(stage2->>'photo_verdict','')='НАРУШЕНИЕ')::int photo_bad,
          COUNT(*)::int total
        FROM agent_decisions WHERE day=%s::date AND itog='НАРУШЕНИЕ (фото)'
        """,
        (day,),
    )
    print(cur.fetchone())

    print("\n=== ответы модели: доля единиц по кодам (checklist 1а) ===")
    cur.execute(
        """
        SELECT
          COUNT(*)::int n,
          SUM(((stage2->'answers'->>'А2')::int))::int a2,
          SUM(((stage2->'answers'->>'А3')::int))::int a3,
          SUM(((stage2->'answers'->>'А4')::int))::int a4,
          SUM(((stage2->'answers'->>'А5')::int))::int a5,
          SUM(((stage2->'answers'->>'О1')::int))::int o1,
          SUM(((stage2->'answers'->>'О3')::int))::int o3
        FROM agent_decisions
        WHERE day=%s::date AND checklist='1а' AND stage2->>'status'='ok'
          AND stage2->'answers'->>'А2' ~ '^[0-9]+$'
        """,
        (day,),
    )
    print(cur.fetchone())

    print("\n=== 1г: Б-коды ===")
    cur.execute(
        """
        SELECT COUNT(*)::int n,
          SUM(((stage2->'answers'->>'Б1')::int))::int b1,
          SUM(((stage2->'answers'->>'Б2')::int))::int b2,
          SUM(((stage2->'answers'->>'Б3')::int))::int b3,
          SUM(((stage2->'answers'->>'Б5')::int))::int b5
        FROM agent_decisions
        WHERE day=%s::date AND checklist='1г' AND stage2->>'status'='ok'
          AND stage2->'answers'->>'Б1' ~ '^[0-9]+$'
        """,
        (day,),
    )
    print(cur.fetchone())

    print("\n=== 1б: С-коды ===")
    cur.execute(
        """
        SELECT COUNT(*)::int n,
          SUM(((stage2->'answers'->>'С1')::int))::int c1,
          SUM(((stage2->'answers'->>'С2')::int))::int c2,
          SUM(((stage2->'answers'->>'С3')::int))::int c3
        FROM agent_decisions
        WHERE day=%s::date AND checklist='1б' AND stage2->>'status'='ok'
          AND stage2->'answers'->>'С1' ~ '^[0-9]+$'
        """,
        (day,),
    )
    print(cur.fetchone())

    print("\n=== О3 (подделка) сработал ===")
    cur.execute(
        """
        SELECT COUNT(*)::int n FROM agent_decisions
        WHERE day=%s::date AND stage2->'answers'->>'О3'='1'
        """,
        (day,),
    )
    print(cur.fetchone())

    print("\n=== примеры комментариев модели у фото-нарушений ===")
    cur.execute(
        """
        SELECT order_id, checklist, za_chto, left(COALESCE(stage2->>'comment',''),160) c
        FROM agent_decisions
        WHERE day=%s::date AND itog='НАРУШЕНИЕ (фото)' AND stage2->>'status'='ok'
        ORDER BY created_at DESC LIMIT 15
        """,
        (day,),
    )
    for r in cur.fetchall():
        print(f"{r['order_id']} {r['checklist']:>3} {r['za_chto']:<18} {r['c']}")
PY
echo DONE
