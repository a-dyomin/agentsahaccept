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
    "GROUP BY itog ORDER BY n DESC", (day,)
):
    print(f"  {r['itog']:<22} {r['n']:5d}  {100.0*r['n']/max(tot,1):5.1f}%")

print("\n=== где фигурирует ГЕО в za_chto ===")
geo_all = q(
    "SELECT COUNT(*)::int n FROM agent_decisions WHERE day=%s::date "
    "AND za_chto ILIKE '%%ГЕО%%'", (day,)
)[0]["n"]
print(f"  всего с ГЕО в za_chto: {geo_all}")

print("\n=== топ комбинаций za_chto с ГЕО ===")
for r in q(
    "SELECT za_chto, COUNT(*)::int n FROM agent_decisions WHERE day=%s::date "
    "AND za_chto ILIKE '%%ГЕО%%' GROUP BY za_chto ORDER BY n DESC LIMIT 20",
    (day,),
):
    print(f"  {r['n']:5d}  {r['za_chto']}")

print("\n=== только ГЕО (без фото-кодов) ===")
only_geo = q(
    "SELECT COUNT(*)::int n FROM agent_decisions WHERE day=%s::date "
    "AND itog='НАРУШЕНИЕ (фото)' AND za_chto NOT LIKE '%%фото:%%' "
    "AND za_chto ILIKE '%%ГЕО%%'",
    (day,),
)[0]["n"]
print(f"  {only_geo}")

print("\n=== ГЕО + фото-коды вместе ===")
geo_and_photo = q(
    "SELECT COUNT(*)::int n FROM agent_decisions WHERE day=%s::date "
    "AND za_chto ILIKE '%%ГЕО%%' AND za_chto LIKE '%%фото:%%'",
    (day,),
)[0]["n"]
print(f"  {geo_and_photo}")

print("\n=== stage1 geo-флаги (из stage1 jsonb) ===")
# типичные ключи: geo_ok / geo_fail / photo_geo / track
for key in ("geo_fail", "geo_ok", "geo_na", "photo_in_radius", "track_ok", "track_fail"):
    try:
        rows = q(
            f"SELECT stage1->>%s v, COUNT(*)::int n FROM agent_decisions "
            f"WHERE day=%s::date AND stage1 ? %s GROUP BY 1 ORDER BY n DESC LIMIT 8",
            (key, day, key),
        )
        if rows:
            print(f"  {key}:")
            for r in rows:
                print(f"    {r['v']!r}: {r['n']}")
    except Exception as exc:
        conn.rollback()
        print(f"  {key}: skip ({exc})")

print("\n=== ключи stage1 (sample) ===")
sample = q(
    "SELECT stage1 FROM agent_decisions WHERE day=%s::date "
    "AND za_chto ILIKE '%%ГЕО%%' LIMIT 1",
    (day,),
)
if sample and sample[0]["stage1"]:
    print(" ", sorted((sample[0]["stage1"] or {}).keys()))

print("\n=== примеры: только ГЕО ===")
for r in q(
    """
    SELECT order_id, itog, za_chto,
           left(COALESCE(pometki,''),80) p,
           stage1->>'geo_fail' gf,
           stage1->>'geo_ok' go,
           stage1->>'photo_radius_m' pr,
           stage1->>'min_photo_dist_m' md,
           stage1->>'coords' coords
    FROM agent_decisions
    WHERE day=%s::date AND itog='НАРУШЕНИЕ (фото)'
      AND za_chto NOT LIKE '%%фото:%%' AND za_chto ILIKE '%%ГЕО%%'
    ORDER BY random() LIMIT 12
    """,
    (day,),
):
    print(
        f"  {r['order_id']}  za={r['za_chto']}  "
        f"geo_fail={r['gf']} geo_ok={r['go']} "
        f"radius={r['pr']} min_dist={r['md']}  "
        f"pometki={r['p']}"
    )

print("\n=== распределение min_photo_dist / geo reason если есть ===")
for key in (
    "min_photo_dist_m", "photo_geo_status", "geo_reason", "geo_status",
    "nearest_photo_m", "photo_ok", "flags",
):
    rows = q(
        "SELECT left(COALESCE(stage1->>%s,''),60) v, COUNT(*)::int n "
        "FROM agent_decisions WHERE day=%s::date AND za_chto ILIKE '%%ГЕО%%' "
        "AND stage1 ? %s GROUP BY 1 ORDER BY n DESC LIMIT 12",
        (key, day, key),
    )
    if rows:
        print(f"\n  stage1.{key}:")
        for r in rows:
            print(f"    {r['v']!r}: {r['n']}")

print("\n=== сверка только-ГЕО с человеком ===")
for r in q(
    """
    SELECT c.agent_itog, c.human_breach_state, c.match_flag, COUNT(*)::int n
    FROM comparisons c
    JOIN agent_decisions d ON d.day=c.day AND d.order_id=c.order_id
    WHERE c.day=%s::date
      AND d.za_chto ILIKE '%%ГЕО%%'
      AND d.za_chto NOT LIKE '%%фото:%%'
    GROUP BY 1,2,3 ORDER BY n DESC LIMIT 15
    """,
    (day,),
):
    print(f"  agent={r['agent_itog']:<22} human={r['human_breach_state']!s:<12} "
          f"match={r['match_flag']}  n={r['n']}")

print("\n=== по чек-листам: только ГЕО ===")
for r in q(
    """
    SELECT COALESCE(checklist,'(нет)') cl, COUNT(*)::int n
    FROM agent_decisions
    WHERE day=%s::date AND itog='НАРУШЕНИЕ (фото)'
      AND za_chto NOT LIKE '%%фото:%%' AND za_chto ILIKE '%%ГЕО%%'
    GROUP BY 1 ORDER BY n DESC
    """,
    (day,),
):
    print(f"  {r['cl']:>6}  {r['n']}")

conn.close()
PY
