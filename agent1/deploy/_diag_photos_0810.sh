#!/bin/bash
set -eu
set -a
# shellcheck disable=SC1091
source /home/admin-akea/agent1/.env
set +a

echo "=== S3 endpoint reachability ==="
EP=$(python3 - <<'PY'
import os
print(os.environ.get("S3_ENDPOINT_URL",""))
PY
)
echo "S3_ENDPOINT_URL=$EP"
if [ -n "$EP" ]; then
  curl -sk --noproxy '*' -o /dev/null -w "s3 http_code=%{http_code} connect=%{time_connect}s total=%{time_total}s\n" -m 20 "$EP" || echo "S3 curl failed"
fi

echo "=== photo cache size ==="
CACHE=$(python3 - <<'PY'
import os
print(os.environ.get("AGENT1_PHOTO_CACHE","/tmp/agent1_photos"))
PY
)
echo "CACHE=$CACHE"
du -sh "$CACHE" 2>/dev/null || echo "no cache dir"
ls "$CACHE" 2>/dev/null | wc -l

echo "=== recent decision stage2 samples (slow vs fast) ==="
/home/admin-akea/agent1/venv/bin/python <<'PY'
import os, json
import psycopg
from psycopg.rows import dict_row
url = next(os.environ[k] for k in ("DATABASE_URL","AGENT1_DATABASE_URL","AGENT1_DB_URL") if os.environ.get(k))
with psycopg.connect(url, row_factory=dict_row) as conn:
    cur = conn.cursor()
    print("SLOW_SAMPLES")
    cur.execute("""
      SELECT order_id, created_at::text, COALESCE(stage2->>'status','none') st,
             left(COALESCE(stage2->>'reason', stage2->>'error', stage2::text), 180) detail
      FROM agent_decisions
      WHERE created_at BETWEEN '2026-08-08 06:00+00' AND '2026-08-10 02:59+00'
      ORDER BY created_at DESC LIMIT 8
    """)
    for r in cur.fetchall():
        print(r)
    print("FAST_SAMPLES")
    cur.execute("""
      SELECT order_id, created_at::text, COALESCE(stage2->>'status','none') st,
             left(COALESCE(stage2->>'reason', stage2->>'error', stage2::text), 180) detail
      FROM agent_decisions
      WHERE created_at > '2026-08-10 03:00+00'
      ORDER BY created_at DESC LIMIT 8
    """)
    for r in cur.fetchall():
        print(r)

    # queue remaining by run/day
    cur.execute("""
      SELECT r.day::text d, j.status, COUNT(*)::int n
      FROM jobs j JOIN runs r ON r.id=j.run_id
      WHERE j.status IN ('queued','leased')
      GROUP BY 1,2 ORDER BY 1,2
    """)
    print("QUEUE_BY_DAY", cur.fetchall())

    # estimate ETA at current speed (~1700/h)
    cur.execute("SELECT COUNT(*)::int n FROM jobs WHERE status='queued'")
    q = cur.fetchone()['n']
    print(f"QUEUED={q} ETA_HOURS_AT_1700PH={round(q/1700,1)}")
PY

echo "=== stuck leased job age ==="
/home/admin-akea/agent1/venv/bin/python <<'PY'
import os
import psycopg
from psycopg.rows import dict_row
url = next(os.environ[k] for k in ("DATABASE_URL","AGENT1_DATABASE_URL","AGENT1_DB_URL") if os.environ.get(k))
with psycopg.connect(url, row_factory=dict_row) as conn:
    cur = conn.cursor()
    cur.execute("""
      SELECT j.id::text, j.order_id, j.status, j.leased_at::text,
             EXTRACT(EPOCH FROM (now()-j.leased_at))/3600 AS hours_leased,
             left(COALESCE(j.payload->>'photo_urls', j.payload::text), 120) p
      FROM jobs j WHERE status='leased'
    """)
    for r in cur.fetchall():
        print(r)
PY

echo "=== live status snapshot ==="
curl -sS --noproxy '*' -m 30 'http://127.0.0.1:8101/api/status' | /home/admin-akea/agent1/venv/bin/python -c 'import sys,json;d=json.load(sys.stdin);print({k:d.get(k) for k in ("agent_state","active_run")});c=d.get("counts",{});print({k:c.get(k) for k in ("queued","in_progress","processed","errors")})'
echo DONE
