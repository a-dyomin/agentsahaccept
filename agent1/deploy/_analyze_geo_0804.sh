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

print("=== ingest ===")
print(" ", q("SELECT day::text, status, counts, exported_at, error FROM ingest_snapshots WHERE day=%s::date", (day,)))

print("\n=== runs / jobs ===")
print(" ", q("SELECT id, status, note, created_at FROM runs WHERE day=%s ORDER BY created_at DESC LIMIT 5", (day,)))
print(" ", q(
    "SELECT j.status, COUNT(*)::int n FROM jobs j "
    "JOIN runs r ON r.id=j.run_id WHERE r.day=%s GROUP BY j.status ORDER BY n DESC",
    (day,),
))

tot = q("SELECT COUNT(*)::int n FROM agent_decisions WHERE day=%s::date", (day,))[0]["n"]
print(f"\nобработано решений: {tot}")
if not tot:
    raise SystemExit(0)

print("\n=== ИТОГ ===")
for r in q(
    "SELECT itog, COUNT(*)::int n FROM agent_decisions WHERE day=%s::date "
    "GROUP BY itog ORDER BY n DESC", (day,)
):
    print(f"  {r['itog']:<22} {r['n']:5d}  {100.0*r['n']/tot:5.1f}%")

print("\n=== производительность ===")
auto = sum(
    r["n"] for r in q(
        "SELECT itog, COUNT(*)::int n FROM agent_decisions WHERE day=%s::date GROUP BY itog",
        (day,),
    )
    if r["itog"] == "ЧИСТО" or str(r["itog"]).startswith("НАРУШЕНИЕ")
)
human = q(
    "SELECT COUNT(*)::int n FROM agent_decisions WHERE day=%s::date AND itog='К ЧЕЛОВЕКУ'",
    (day,),
)[0]["n"]
scope = auto + human
print(f"  auto={auto} human={human} productivity={100.0*auto/scope if scope else 0:.1f}%")

print("\n=== ГЕО в za_chto ===")
geo_all = q(
    "SELECT COUNT(*)::int n FROM agent_decisions WHERE day=%s::date AND za_chto ILIKE '%%ГЕО%%'",
    (day,),
)[0]["n"]
only_geo = q(
    "SELECT COUNT(*)::int n FROM agent_decisions WHERE day=%s::date "
    "AND itog='НАРУШЕНИЕ (фото)' AND za_chto NOT LIKE '%%фото:%%' AND za_chto ILIKE '%%ГЕО%%'",
    (day,),
)[0]["n"]
geo_and_photo = q(
    "SELECT COUNT(*)::int n FROM agent_decisions WHERE day=%s::date "
    "AND za_chto ILIKE '%%ГЕО%%' AND za_chto LIKE '%%фото:%%'",
    (day,),
)[0]["n"]
pv = q(
    "SELECT COUNT(*)::int n FROM agent_decisions WHERE day=%s::date AND itog='НАРУШЕНИЕ (фото)'",
    (day,),
)[0]["n"]
print(f"  всего с ГЕО: {geo_all}")
print(f"  только ГЕО (без фото-кодов): {only_geo}")
print(f"  ГЕО+фото вместе: {geo_and_photo}")
print(f"  доля только-ГЕО среди НАРУШЕНИЕ (фото): {100.0*only_geo/max(pv,1):.1f}% ({only_geo}/{pv})")

print("\n=== топ za_chto с ГЕО ===")
for r in q(
    "SELECT za_chto, COUNT(*)::int n FROM agent_decisions WHERE day=%s::date "
    "AND za_chto ILIKE '%%ГЕО%%' GROUP BY za_chto ORDER BY n DESC LIMIT 15",
    (day,),
):
    print(f"  {r['n']:5d}  {r['za_chto']}")

print("\n=== stage1.ГЕО по всем решениям ===")
for r in q(
    "SELECT stage1->>'ГЕО' v, COUNT(*)::int n FROM agent_decisions WHERE day=%s::date "
    "GROUP BY 1 ORDER BY n DESC",
    (day,),
):
    print(f"  ГЕО={r['v']!r}: {r['n']}")

print("\n=== бакеты ГЕО_МИН_М среди ГЕО-нарушений ===")
stats = q(
    """
    SELECT COUNT(*)::int n,
      ROUND(AVG((stage1->>'ГЕО_МИН_М')::numeric),1) avg_m,
      ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY (stage1->>'ГЕО_МИН_М')::numeric)::numeric,1) p50,
      ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY (stage1->>'ГЕО_МИН_М')::numeric)::numeric,1) p90,
      ROUND(MIN((stage1->>'ГЕО_МИН_М')::numeric),1) mn,
      ROUND(MAX((stage1->>'ГЕО_МИН_М')::numeric),1) mx
    FROM agent_decisions
    WHERE day=%s::date AND za_chto ILIKE '%%ГЕО%%'
      AND stage1->>'ГЕО_МИН_М' ~ '^[0-9.]+$'
    """,
    (day,),
)[0]
print(" ", stats)

for r in q(
    """
    SELECT
      CASE
        WHEN (stage1->>'ГЕО_МИН_М')::numeric < 100 THEN '<100м (БАГ!)'
        WHEN (stage1->>'ГЕО_МИН_М')::numeric < 150 THEN '100–150м'
        WHEN (stage1->>'ГЕО_МИН_М')::numeric < 200 THEN '150–200м'
        WHEN (stage1->>'ГЕО_МИН_М')::numeric < 500 THEN '200–500м'
        WHEN (stage1->>'ГЕО_МИН_М')::numeric < 1000 THEN '500м–1км'
        WHEN (stage1->>'ГЕО_МИН_М')::numeric < 5000 THEN '1–5км'
        ELSE '>=5км'
      END bucket,
      COUNT(*)::int n
    FROM agent_decisions
    WHERE day=%s::date AND za_chto ILIKE '%%ГЕО%%'
      AND stage1->>'ГЕО_МИН_М' ~ '^[0-9.]+$'
    GROUP BY 1
    ORDER BY MIN((stage1->>'ГЕО_МИН_М')::numeric)
    """,
    (day,),
):
    print(f"  {r['bucket']:<18} {r['n']}")

print("\n=== ГЕО флаги среди ГЕО-нарушений ===")
for r in q(
    """
    SELECT stage1->>'ГЕО' g, stage1->>'ГЕО_ВНЕ' out, stage1->>'ГЕО_БЕЗ_КООРД' nc, COUNT(*)::int n
    FROM agent_decisions WHERE day=%s::date AND za_chto ILIKE '%%ГЕО%%'
    GROUP BY 1,2,3 ORDER BY n DESC LIMIT 10
    """,
    (day,),
):
    print(f"  ГЕО={r['g']} ВНЕ={r['out']} БЕЗ_КООРД={r['nc']} → {r['n']}")

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

print("\n=== топ перевозчиков среди только-ГЕО ===")
for r in q(
    """
    SELECT COALESCE(o.provider_name,'(нет)') p, COUNT(*)::int n
    FROM agent_decisions d
    LEFT JOIN orders_day o ON o.day=d.day AND o.order_id=d.order_id
    WHERE d.day=%s::date AND d.itog='НАРУШЕНИЕ (фото)'
      AND d.za_chto NOT LIKE '%%фото:%%' AND d.za_chto ILIKE '%%ГЕО%%'
    GROUP BY 1 ORDER BY n DESC LIMIT 12
    """,
    (day,),
):
    print(f"  {r['n']:5d}  {r['p']}")

print("\n=== ближайшие только-ГЕО (пограничные) ===")
for r in q(
    """
    SELECT d.order_id, d.checklist, d.stage1->>'ГЕО_МИН_М' m, d.stage1->>'ГЕО_ВНЕ' outn,
           o.provider_name, left(COALESCE(o.site_address,''),55) addr
    FROM agent_decisions d
    LEFT JOIN orders_day o ON o.day=d.day AND o.order_id=d.order_id
    WHERE d.day=%s::date AND d.za_chto='ГЕО'
      AND d.stage1->>'ГЕО_МИН_М' ~ '^[0-9.]+$'
    ORDER BY (d.stage1->>'ГЕО_МИН_М')::numeric
    LIMIT 10
    """,
    (day,),
):
    print(f"  {r['order_id']} {r['checklist']} {r['m']}м вне={r['outn']} {r['provider_name']} | {r['addr']}")

print("\n=== самые дальние только-ГЕО ===")
for r in q(
    """
    SELECT d.order_id, d.checklist, d.stage1->>'ГЕО_МИН_М' m,
           o.provider_name, left(COALESCE(o.site_address,''),55) addr
    FROM agent_decisions d
    LEFT JOIN orders_day o ON o.day=d.day AND o.order_id=d.order_id
    WHERE d.day=%s::date AND d.za_chto='ГЕО'
      AND d.stage1->>'ГЕО_МИН_М' ~ '^[0-9.]+$'
    ORDER BY (d.stage1->>'ГЕО_МИН_М')::numeric DESC
    LIMIT 10
    """,
    (day,),
):
    print(f"  {r['order_id']} {r['checklist']} {r['m']}м {r['provider_name']} | {r['addr']}")

print("\n=== фото ПОДТВЕРЖДЕНО, но упало по ГЕО ===")
print(" ", q(
    """
    SELECT COUNT(*)::int n,
      COUNT(*) FILTER (WHERE za_chto ILIKE '%%ГЕО%%')::int with_geo,
      COUNT(*) FILTER (WHERE za_chto='ГЕО')::int only_geo
    FROM agent_decisions
    WHERE day=%s::date AND stage2->>'photo_verdict'='ПОДТВЕРЖДЕНО'
    """,
    (day,),
)[0])

print("\n=== сверка только-ГЕО с человеком ===")
for r in q(
    """
    SELECT c.human_breach_state, c.match_flag, COUNT(*)::int n
    FROM comparisons c
    JOIN agent_decisions d ON d.day=c.day AND d.order_id=c.order_id
    WHERE c.day=%s::date AND d.za_chto ILIKE '%%ГЕО%%' AND d.za_chto NOT LIKE '%%фото:%%'
    GROUP BY 1,2 ORDER BY n DESC LIMIT 10
    """,
    (day,),
):
    print(f"  human={r['human_breach_state']!s:<12} match={r['match_flag']} n={r['n']}")

print("\n=== сравнение 03 vs 04: доля ГЕО ===")
for d in ("2026-08-03", "2026-08-04"):
    t = q("SELECT COUNT(*)::int n FROM agent_decisions WHERE day=%s::date", (d,))[0]["n"]
    g = q(
        "SELECT COUNT(*)::int n FROM agent_decisions WHERE day=%s::date AND za_chto ILIKE '%%ГЕО%%'",
        (d,),
    )[0]["n"]
    og = q(
        "SELECT COUNT(*)::int n FROM agent_decisions WHERE day=%s::date "
        "AND itog='НАРУШЕНИЕ (фото)' AND za_chto NOT LIKE '%%фото:%%' AND za_chto ILIKE '%%ГЕО%%'",
        (d,),
    )[0]["n"]
    print(f"  {d}: решений={t} с ГЕО={g} ({100.0*g/max(t,1):.1f}%) только-ГЕО={og}")

conn.close()
PY
