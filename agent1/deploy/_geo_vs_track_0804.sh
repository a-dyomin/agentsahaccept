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

url = next(os.environ[k] for k in ("DATABASE_URL","AGENT1_DATABASE_URL","AGENT1_DB_URL") if os.environ.get(k))
day = "2026-08-04"
conn = psycopg.connect(url, row_factory=dict_row)
cur = conn.cursor()

print("=== среди только-ГЕО: что с ТРЕКом и ФОТО_ДОЕЗД ===")
cur.execute("""
 SELECT stage1->>'ТРЕК' track,
        stage1->>'ФОТО_ДОЕЗД' doezd,
        stage1->>'ТРЕК_ЕСТЬ' exists,
        COUNT(*)::int n
 FROM agent_decisions
 WHERE day=%s::date AND itog='НАРУШЕНИЕ (фото)'
   AND za_chto NOT LIKE '%%фото:%%' AND za_chto ILIKE '%%ГЕО%%'
 GROUP BY 1,2,3 ORDER BY n DESC
""", (day,))
for r in cur.fetchall():
    print(f"  ТРЕК={r['track']!s:<4} ФОТО_ДОЕЗД={r['doezd']!s:<4} ТРЕК_ЕСТЬ={r['exists']!s:<4} → {r['n']}")

print("\n=== ГЕО упало, но ТРЕК=1 (машина была у площадки) ===")
cur.execute("""
 SELECT COUNT(*)::int n,
   ROUND(AVG((stage1->>'ГЕО_МИН_М')::numeric),1) avg_photo_m,
   ROUND(AVG((stage1->>'ТРЕК_М')::numeric),1) avg_track_m
 FROM agent_decisions
 WHERE day=%s::date AND za_chto ILIKE '%%ГЕО%%'
   AND stage1->>'ТРЕК'='1'
""", (day,))
print(" ", cur.fetchone())

print("\n=== ГЕО упало + ТРЕК=1 + photo_verdict ПОДТВЕРЖДЕНО ===")
cur.execute("""
 SELECT COUNT(*)::int n
 FROM agent_decisions
 WHERE day=%s::date AND za_chto ILIKE '%%ГЕО%%'
   AND stage1->>'ТРЕК'='1'
   AND stage2->>'photo_verdict'='ПОДТВЕРЖДЕНО'
""", (day,))
print(" ", cur.fetchone())

print("\n=== бакеты photo_m при ТРЕК=1 и ГЕО-fail ===")
cur.execute("""
 SELECT
   CASE
     WHEN (stage1->>'ГЕО_МИН_М')::numeric < 150 THEN '100–150м'
     WHEN (stage1->>'ГЕО_МИН_М')::numeric < 300 THEN '150–300м'
     WHEN (stage1->>'ГЕО_МИН_М')::numeric < 1000 THEN '300м–1км'
     ELSE '>=1км'
   END b, COUNT(*)::int n
 FROM agent_decisions
 WHERE day=%s::date AND za_chto ILIKE '%%ГЕО%%' AND stage1->>'ТРЕК'='1'
   AND stage1->>'ГЕО_МИН_М' ~ '^[0-9.]+$'
 GROUP BY 1 ORDER BY MIN((stage1->>'ГЕО_МИН_М')::numeric)
""", (day,))
for r in cur.fetchall():
    print(f"  {r['b']:<12} {r['n']}")
conn.close()
PY
