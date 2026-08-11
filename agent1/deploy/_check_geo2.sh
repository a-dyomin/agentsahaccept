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

print("=== stage1.ГЕО / ГЕО_МИН_М / ГЕО_ВНЕ / ГЕО_БЕЗ_КООРД ===")
for key in ("ГЕО", "ГЕО_ВНЕ", "ГЕО_БЕЗ_КООРД", "ФОТО", "ФОТО_КОЛ", "ТРЕК"):
    rows = q(
        "SELECT stage1->>%s v, COUNT(*)::int n FROM agent_decisions "
        "WHERE day=%s::date GROUP BY 1 ORDER BY n DESC LIMIT 10",
        (key, day),
    )
    print(f"\n  {key}:")
    for r in rows:
        print(f"    {r['v']!r}: {r['n']}")

print("\n=== среди za_chto с ГЕО: распределение ГЕО_МИН_М ===")
rows = q(
    """
    SELECT
      COUNT(*)::int n,
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
)
print(" ", rows[0])

print("\n=== бакеты дистанции (только ГЕО в za_chto) ===")
for r in q(
    """
    SELECT
      CASE
        WHEN (stage1->>'ГЕО_МИН_М')::numeric < 100 THEN '<100м (в радиусе?!)'
        WHEN (stage1->>'ГЕО_МИН_М')::numeric < 150 THEN '100–150м'
        WHEN (stage1->>'ГЕО_МИН_М')::numeric < 200 THEN '150–200м'
        WHEN (stage1->>'ГЕО_МИН_М')::numeric < 500 THEN '200–500м'
        WHEN (stage1->>'ГЕО_МИН_М')::numeric < 1000 THEN '500м–1км'
        ELSE '>=1км'
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
    print(f"  {r['bucket']:<22} {r['n']}")

print("\n=== ГЕО_ВНЕ / ГЕО_БЕЗ_КООРД среди ГЕО-нарушений ===")
for r in q(
    """
    SELECT stage1->>'ГЕО' g, stage1->>'ГЕО_ВНЕ' out, stage1->>'ГЕО_БЕЗ_КООРД' nc,
           COUNT(*)::int n
    FROM agent_decisions
    WHERE day=%s::date AND za_chto ILIKE '%%ГЕО%%'
    GROUP BY 1,2,3 ORDER BY n DESC
    """,
    (day,),
):
    print(f"  ГЕО={r['g']}  ВНЕ={r['out']}  БЕЗ_КООРД={r['nc']}  → {r['n']}")

print("\n=== для сравнения: чистые заявки — ГЕО флаги ===")
for r in q(
    """
    SELECT stage1->>'ГЕО' g, COUNT(*)::int n
    FROM agent_decisions WHERE day=%s::date AND itog='ЧИСТО'
    GROUP BY 1 ORDER BY n DESC
    """,
    (day,),
):
    print(f"  ЧИСТО ГЕО={r['g']!r}: {r['n']}")

print("\n=== порог: что в export / payload (sample orders_day) ===")
# look at raw order fields if any
cols = q(
    """
    SELECT column_name FROM information_schema.columns
    WHERE table_name='orders_day' AND column_name ILIKE '%%geo%%'
       OR (table_name='orders_day' AND column_name ILIKE '%%coord%%')
       OR (table_name='orders_day' AND column_name ILIKE '%%radius%%')
       OR (table_name='orders_day' AND column_name ILIKE '%%dist%%')
    ORDER BY 1
    """
)
print("  orders_day geo-ish cols:", [c["column_name"] for c in cols])

print("\n=== примеры только-ГЕО с дистанцией ===")
for r in q(
    """
    SELECT order_id, checklist, za_chto,
           stage1->>'ГЕО_МИН_М' m,
           stage1->>'ГЕО_ВНЕ' outn,
           stage1->>'ФОТО_КОЛ' fotos,
           stage1->>'ТРЕК' track,
           left(COALESCE(pometki,''),70) p
    FROM agent_decisions
    WHERE day=%s::date AND za_chto = 'ГЕО'
      AND stage1->>'ГЕО_МИН_М' ~ '^[0-9.]+$'
    ORDER BY (stage1->>'ГЕО_МИН_М')::numeric
    LIMIT 8
    """,
    (day,),
):
    print(f"  {r['order_id']} {r['checklist']}  {r['m']}м  вне={r['outn']} "
          f"фото={r['fotos']} трек={r['track']}  {r['p']}")

print("\n=== самые дальние только-ГЕО ===")
for r in q(
    """
    SELECT order_id, checklist, stage1->>'ГЕО_МИН_М' m, stage1->>'ГЕО_ВНЕ' outn
    FROM agent_decisions
    WHERE day=%s::date AND za_chto = 'ГЕО'
      AND stage1->>'ГЕО_МИН_М' ~ '^[0-9.]+$'
    ORDER BY (stage1->>'ГЕО_МИН_М')::numeric DESC
    LIMIT 8
    """,
    (day,),
):
    print(f"  {r['order_id']} {r['checklist']}  {r['m']}м  вне={r['outn']}")

print("\n=== доля ГЕО среди НАРУШЕНИЕ (фото) ===")
pv = q("SELECT COUNT(*)::int n FROM agent_decisions WHERE day=%s::date AND itog='НАРУШЕНИЕ (фото)'", (day,))[0]["n"]
only = q(
    "SELECT COUNT(*)::int n FROM agent_decisions WHERE day=%s::date "
    "AND itog='НАРУШЕНИЕ (фото)' AND za_chto NOT LIKE '%%фото:%%' AND za_chto ILIKE '%%ГЕО%%'",
    (day,),
)[0]["n"]
print(f"  фото-нарушений: {pv}, из них только ГЕО: {only} ({100.0*only/max(pv,1):.1f}%)")

print("\n=== ГЕО среди заявок, где фото ПОДТВЕРЖДЕНО (stage2) ===")
for r in q(
    """
    SELECT COUNT(*)::int n,
      COUNT(*) FILTER (WHERE za_chto ILIKE '%%ГЕО%%')::int with_geo,
      COUNT(*) FILTER (WHERE za_chto = 'ГЕО')::int only_geo
    FROM agent_decisions
    WHERE day=%s::date AND stage2->>'photo_verdict'='ПОДТВЕРЖДЕНО'
    """,
    (day,),
):
    print(" ", r)

conn.close()
PY
