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

    print("=== имена файлов фото за день (шаблон времени) ===")
    cur.execute(
        """
        SELECT
          COUNT(*)::int total,
          COUNT(*) FILTER (WHERE filename ~* '(JPEG|IMG|DSC)[_-]?[0-9]{8}[_-][0-9]{6}')::int with_time,
          COUNT(*) FILTER (WHERE filename ILIKE '%%.png')::int png
        FROM photos_day WHERE day=%s::date
        """,
        (day,),
    )
    print(cur.fetchone())

    cur.execute(
        "SELECT filename FROM photos_day WHERE day=%s::date ORDER BY photo_id DESC LIMIT 8",
        (day,),
    )
    print("примеры имён:", [r["filename"] for r in cur.fetchall()])

    print("\n=== О3=1: какие файлы у этих заявок ===")
    cur.execute(
        """
        SELECT d.order_id,
               d.za_chto,
               left(COALESCE(d.stage2->>'comment',''),90) c,
               (SELECT string_agg(p.filename, ' | ') FROM photos_day p
                 WHERE p.day=d.day AND p.order_id=d.order_id) files
        FROM agent_decisions d
        WHERE d.day=%s::date AND d.stage2->'answers'->>'О3'='1'
        ORDER BY d.created_at DESC LIMIT 12
        """,
        (day,),
    )
    for r in cur.fetchall():
        print(f"{r['order_id']} | {r['za_chto']}")
        print(f"    files: {str(r['files'])[:150]}")
        print(f"    comment: {r['c']}")

    print("\n=== О3=1 доля файлов PNG vs JPG ===")
    cur.execute(
        """
        WITH o3 AS (
          SELECT order_id FROM agent_decisions
          WHERE day=%s::date AND stage2->'answers'->>'О3'='1'
        )
        SELECT
          COUNT(*)::int photos,
          COUNT(*) FILTER (WHERE filename ILIKE '%%.png')::int png,
          COUNT(*) FILTER (WHERE filename ~* '(JPEG|IMG)[_-]?[0-9]{8}[_-][0-9]{6}')::int normal_app_name
        FROM photos_day p JOIN o3 ON o3.order_id=p.order_id
        WHERE p.day=%s::date
        """,
        (day, day),
    )
    print(cur.fetchone())

    print("\n=== для сравнения: О3=0 ===")
    cur.execute(
        """
        WITH o3 AS (
          SELECT order_id FROM agent_decisions
          WHERE day=%s::date AND stage2->'answers'->>'О3'='0'
        )
        SELECT
          COUNT(*)::int photos,
          COUNT(*) FILTER (WHERE filename ILIKE '%%.png')::int png,
          COUNT(*) FILTER (WHERE filename ~* '(JPEG|IMG)[_-]?[0-9]{8}[_-][0-9]{6}')::int normal_app_name
        FROM photos_day p JOIN o3 ON o3.order_id=p.order_id
        WHERE p.day=%s::date
        """,
        (day, day),
    )
    print(cur.fetchone())

    print("\n=== А3=1 примеры (их всего мало) ===")
    cur.execute(
        """
        SELECT order_id, itog, left(COALESCE(stage2->>'comment',''),100) c
        FROM agent_decisions
        WHERE day=%s::date AND stage2->'answers'->>'А3'='1' LIMIT 5
        """,
        (day,),
    )
    for r in cur.fetchall():
        print(r)

    print("\n=== сколько заявок с 2+ фото и валидным временем ===")
    cur.execute(
        """
        SELECT COUNT(*)::int n FROM (
          SELECT order_id
          FROM photos_day
          WHERE day=%s::date
            AND filename ~* '(JPEG|IMG|DSC)[_-]?[0-9]{8}[_-][0-9]{6}'
          GROUP BY order_id HAVING COUNT(*)>=2
        ) t
        """,
        (day,),
    )
    print(cur.fetchone())
PY
echo DONE
