#!/bin/bash
set -eu
APP=/home/admin-akea/agent1/app
set -a
# shellcheck disable=SC1091
source /home/admin-akea/agent1/.env
set +a
PY=/home/admin-akea/agent1/venv/bin/python

echo "=== GEO_ПО_ТРЕКУ in stage1 ==="
grep -n "ГЕО_ПО_ТРЕКУ\|geo_na_no_coords\|место не проверено" "$APP/stage1_shadow.py" || true

echo "=== writeback hints ==="
grep -nE "writeback|greta_ro|Отменено РО|shadow" "$APP/main.py" "$APP/worker.py" 2>/dev/null | head -40 || true

echo "=== GEO_ПО_ТРЕКУ counts ==="
"$PY" -c '
import os,psycopg
from psycopg.rows import dict_row
url=next(os.environ[k] for k in ("DATABASE_URL","AGENT1_DATABASE_URL","AGENT1_DB_URL") if os.environ.get(k))
with psycopg.connect(url,row_factory=dict_row) as conn:
  cur=conn.cursor()
  cur.execute("""SELECT day::text AS d,
    COUNT(*) FILTER (WHERE stage1->>'\''ГЕО_ПО_ТРЕКУ'\''='\''1'\'')::int AS geo_track
    FROM agent_decisions GROUP BY day ORDER BY day""")
  print(cur.fetchall())
  cur.execute("""SELECT COUNT(*)::int AS n FROM agent_decisions
    WHERE itog='\''К ЧЕЛОВЕКУ'\'' AND (pometki ILIKE '\''%место не проверено%'\'' OR stage1->>'\''ГЕО'\''='\''ND'\'')""")
  print("human with geo ND / mesto:", cur.fetchone())
'

echo "=== github from VM ==="
curl -sS -m 8 -o /dev/null -w "github:%{http_code}\n" https://api.github.com/ || echo github_fail

echo "=== radii ==="
grep -n "RADIUS\|TIME\|MINUTE\|7\|5" /home/admin-akea/agent1/greta/export_day.rb | head -30
