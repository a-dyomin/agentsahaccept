#!/bin/bash
set -eu
set -a
# shellcheck disable=SC1091
source /home/admin-akea/agent1/.env
set +a
cd /home/admin-akea/agent1/app
../venv/bin/python <<'PY'
"""Что лежит в answers vs answers_model по О3 на свежем прогоне."""
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

print("=== 1а: модель vs внутренний О3 ===")
cur.execute(
    """
    SELECT
      COUNT(*)::int n,
      COUNT(*) FILTER (WHERE stage2->'answers_model'->>'О3'='1')::int model_ok,
      COUNT(*) FILTER (WHERE stage2->'answers_model'->>'О3'='0')::int model_fake,
      COUNT(*) FILTER (WHERE stage2->'answers'->>'О3'='1')::int int_fake,
      COUNT(*) FILTER (WHERE stage2->'answers'->>'О3'='0')::int int_ok
    FROM agent_decisions
    WHERE day=%s::date AND checklist='1а' AND stage2->>'status'='ok'
      AND stage2->'answers_model'->>'О3' IS NOT NULL
    """,
    (day,),
)
print(" ", cur.fetchone())

print("\n=== примеры: модель О3=0, комментарий ===")
cur.execute(
    """
    SELECT order_id,
           stage2->'answers_model'->>'О3' m,
           stage2->'answers'->>'О3' i,
           left(COALESCE(stage2->>'comment',''),100) c
    FROM agent_decisions
    WHERE day=%s::date AND checklist='1а' AND stage2->'answers_model'->>'О3'='0'
    ORDER BY random() LIMIT 8
    """,
    (day,),
)
for r in cur.fetchall():
    print(f"  {r['order_id']} model={r['m']} int={r['i']}  {r['c']}")

print("\n=== FALLBACK_NOTE в живом коде ===")
import stage2
print(repr(stage2.FALLBACK_NOTE))
print("POSITIVE", stage2.__dict__.get("POSITIVE") or "—")
from checklist_verdict import POSITIVE_CODES
print("POSITIVE_CODES", POSITIVE_CODES)
print("frame_label 1а", stage2.frame_label("1а", "site_after"))
print("frame_label 2 ", stage2.frame_label("2", "site_after"))
conn.close()
PY
