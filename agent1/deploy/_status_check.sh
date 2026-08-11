#!/bin/bash
set -eu
export PATH=/home/admin-akea/agent1/venv/bin:/usr/bin
NP="curl --noproxy '*'"

echo "=== HEALTH ==="
$NP -sS -m 8 http://127.0.0.1:8101/api/health; echo

echo "=== STATUS SUMMARY ==="
$NP -sS -m 15 "http://127.0.0.1:8101/api/status" -o /tmp/st.json
python3 <<'PY'
import json
d=json.load(open("/tmp/st.json"))
print("agent_state", d.get("agent_state"))
print("active_run", d.get("active_run"))
print("last_ingest", d.get("last_ingest"))
print("counts", d.get("counts"))
print("costs", d.get("costs"))
print("available_days", d.get("available_days"))
print("--- recent events ---")
for e in (d.get("recent_events") or [])[:12]:
    print(e.get("ts"), e.get("level"), e.get("message"))
print("--- recent results ---")
for r in (d.get("recent_results") or [])[:8]:
    print(r.get("order_id"), r.get("agent_verdict"), r.get("za_chto"), "|", r.get("pometki"))
print("--- itog dist ---")
# may be under different key
for k in ("itog_dist","itog","distribution"):
    if k in d: print(k, d[k])
PY

echo
echo "=== DB QUEUE / VISION ==="
cd /home/admin-akea/agent1
# shellcheck disable=SC1091
set -a; source .env; set +a
python3 <<'PY'
import os, json
import psycopg
from psycopg.rows import dict_row
url=os.environ.get("DATABASE_URL") or os.environ.get("AGENT1_DATABASE_URL")
# try common env
for k in ("DATABASE_URL","AGENT1_DB_URL","AGENT1_DATABASE_URL","POSTGRES_URL"):
    if os.environ.get(k):
        url=os.environ[k]; break
# parse from .env style if needed
if not url:
    # fall back: read known local
    print("NO_DB_URL")
    raise SystemExit(0)
with psycopg.connect(url, row_factory=dict_row) as conn:
    with conn.cursor() as cur:
        cur.execute("SELECT status, COUNT(*) n FROM jobs GROUP BY status ORDER BY n DESC")
        print("jobs:", cur.fetchall())
        cur.execute("SELECT day, status, counts, exported_at, error FROM ingest_snapshots ORDER BY day DESC LIMIT 5")
        for r in cur.fetchall():
            print("ingest", r["day"], r["status"], r.get("counts"), "err=", r.get("error"))
        cur.execute("""
          SELECT day, COUNT(*) n, COALESCE(SUM(cost_usd),0) cost, COALESCE(SUM(total_tokens),0) tok
          FROM vision_usage GROUP BY day ORDER BY day DESC LIMIT 5
        """)
        print("vision_usage_by_day:", cur.fetchall())
        cur.execute("""
          SELECT itog, COUNT(*) n FROM agent_decisions
          WHERE day=(SELECT MAX(day) FROM agent_decisions)
          GROUP BY itog ORDER BY n DESC
        """)
        print("latest_day_itog:", cur.fetchall())
        cur.execute("SELECT MAX(day) AS d, COUNT(*) AS n FROM agent_decisions")
        print("decisions_total:", cur.fetchone())
        cur.execute("""
          SELECT created_at, order_id, itog, za_chto, left(coalesce(pometki,''),80) p
          FROM agent_decisions ORDER BY created_at DESC LIMIT 8
        """)
        print("last_decisions:")
        for r in cur.fetchall():
            print(r)
        cur.execute("""
          SELECT j.id, j.status, j.order_id, left(coalesce(j.last_error,''),200) err, j.updated_at
          FROM jobs j WHERE status IN ('error','leased') ORDER BY updated_at DESC LIMIT 10
        """)
        print("error/leased jobs:")
        for r in cur.fetchall():
            print(r)
        # stage2 statuses from recent decisions detail
        cur.execute("""
          SELECT
            COALESCE(stage2->>'status','?') st,
            COUNT(*) n
          FROM agent_decisions
          WHERE day=(SELECT MAX(day) FROM agent_decisions)
          GROUP BY 1 ORDER BY n DESC
        """)
        print("stage2_status_latest_day:", cur.fetchall())
        cur.execute("""
          SELECT order_id, itog, stage2->>'status' st, stage2->>'reason' reason, left(coalesce(stage2->>'comment',''),120) c
          FROM agent_decisions
          WHERE day=(SELECT MAX(day) FROM agent_decisions)
            AND COALESCE(stage2->>'status','') NOT IN ('ok','skipped')
          ORDER BY created_at DESC LIMIT 15
        """)
        print("non-ok stage2 samples:")
        for r in cur.fetchall():
            print(r)
PY

echo
echo "=== JOURNAL (vision/429/billing) ==="
journalctl -u agent1-worker -u agent1-api --since "2026-08-04 20:00" --no-pager 2>/dev/null | grep -iE '429|insufficient|billing|quota|balance|vision_error|error|Traceback|payment|credit' | tail -60 || true
echo
echo "=== WORKER TAIL ==="
journalctl -u agent1-worker -n 40 --no-pager 2>/dev/null | tail -40
echo DONE
