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

print("=== если порог был 150м / 200м — сколько ГЕО ушло бы ===")
for thr in (100, 150, 200, 300):
    n = q(
        """
        SELECT COUNT(*)::int n FROM agent_decisions
        WHERE day=%s::date AND za_chto ILIKE '%%ГЕО%%'
          AND stage1->>'ГЕО_МИН_М' ~ '^[0-9.]+$'
          AND (stage1->>'ГЕО_МИН_М')::numeric > %s
        """,
        (day, thr),
    )[0]["n"]
    saved = q(
        """
        SELECT COUNT(*)::int n FROM agent_decisions
        WHERE day=%s::date AND za_chto ILIKE '%%ГЕО%%'
          AND stage1->>'ГЕО_МИН_М' ~ '^[0-9.]+$'
          AND (stage1->>'ГЕО_МИН_М')::numeric > 100
          AND (stage1->>'ГЕО_МИН_М')::numeric <= %s
        """,
        (day, thr),
    )[0]["n"]
    print(f"  порог {thr}м: осталось бы ГЕО={n}, «спасли» бы от текущего 100м: {saved if thr>100 else 0}")

print("\n=== ГЕО=1 (ок) — распределение min_m для сравнения ===")
print(" ", q(
    """
    SELECT COUNT(*)::int n,
      ROUND(AVG((stage1->>'ГЕО_МИН_М')::numeric),1) avg_m,
      ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY (stage1->>'ГЕО_МИН_М')::numeric)::numeric,1) p50,
      ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY (stage1->>'ГЕО_МИН_М')::numeric)::numeric,1) p90,
      ROUND(MAX((stage1->>'ГЕО_МИН_М')::numeric),1) mx
    FROM agent_decisions
    WHERE day=%s::date AND stage1->>'ГЕО'='1'
      AND stage1->>'ГЕО_МИН_М' ~ '^[0-9.]+$'
    """,
    (day,),
)[0])

print("\n=== гистограмма 100–120м (тонкая граница) ===")
for r in q(
    """
    SELECT width_bucket((stage1->>'ГЕО_МИН_М')::numeric, 100, 120, 4) b,
           COUNT(*)::int n,
           ROUND(MIN((stage1->>'ГЕО_МИН_М')::numeric),1) mn,
           ROUND(MAX((stage1->>'ГЕО_МИН_М')::numeric),1) mx
    FROM agent_decisions
    WHERE day=%s::date AND za_chto ILIKE '%%ГЕО%%'
      AND (stage1->>'ГЕО_МИН_М')::numeric >= 100
      AND (stage1->>'ГЕО_МИН_М')::numeric < 120
    GROUP BY 1 ORDER BY 1
    """,
    (day,),
):
    print(f"  {r['mn']}–{r['mx']}м: {r['n']}")

print("\n=== кластеры дальних (>=5км) по перевозчику/району ===")
for r in q(
    """
    SELECT COALESCE(o.provider_name,'?') p,
           left(split_part(COALESCE(o.site_address,''), ',', 2),40) district,
           COUNT(*)::int n,
           ROUND(AVG((d.stage1->>'ГЕО_МИН_М')::numeric)/1000,1) avg_km
    FROM agent_decisions d
    LEFT JOIN orders_day o ON o.day=d.day AND o.order_id=d.order_id
    WHERE d.day=%s::date AND d.za_chto ILIKE '%%ГЕО%%'
      AND (d.stage1->>'ГЕО_МИН_М')::numeric >= 5000
    GROUP BY 1,2 ORDER BY n DESC LIMIT 15
    """,
    (day,),
):
    print(f"  {r['n']:4d}  {r['p']:<16} {r['district']:<40} avg={r['avg_km']}км")

print("\n=== прогресс прогона ===")
print(" ", q(
    "SELECT j.status, COUNT(*)::int n FROM jobs j JOIN runs r ON r.id=j.run_id "
    "WHERE r.day=%s GROUP BY j.status",
    (day,),
))
conn.close()
PY
