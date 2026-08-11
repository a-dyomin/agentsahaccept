#!/bin/bash
set -eu
curl --noproxy '*' -sS -m 20 http://127.0.0.1:8101/api/status -o /tmp/st.json
python3 <<'PY'
import json
d=json.load(open("/tmp/st.json"))
print("agent_state:", d.get("agent_state"))
print("active_run:", d.get("active_run"))
print("last_ingest:", d.get("last_ingest"))
print("counts:", json.dumps(d.get("counts"), ensure_ascii=False))
print("costs:", json.dumps(d.get("costs"), ensure_ascii=False))
print("days:", d.get("available_days"))
print("events:")
for e in (d.get("recent_events") or [])[:15]:
    print(" ", e.get("ts"), e.get("level"), e.get("message"))
print("results:")
for r in (d.get("recent_results") or [])[:10]:
    print(" ", r.get("order_id"), r.get("agent_verdict"), "|", r.get("za_chto"), "|", r.get("pometki"))
PY

cd /home/admin-akea/agent1
set -a
# shellcheck disable=SC1091
source .env
set +a
python3 <<'PY'
import os
import psycopg
from psycopg.rows import dict_row

# discover db url
url = None
for k in ("DATABASE_URL", "AGENT1_DATABASE_URL", "AGENT1_DB_URL", "POSTGRES_URL"):
    if os.environ.get(k):
        url = os.environ[k]
        break
if not url:
    host=os.environ.get("PGHOST","127.0.0.1")
    port=os.environ.get("PGPORT","5432")
    db=os.environ.get("PGDATABASE") or os.environ.get("AGENT1_PGDATABASE") or "agent1"
    user=os.environ.get("PGUSER") or os.environ.get("AGENT1_PGUSER") or "agent1"
    pw=os.environ.get("PGPASSWORD") or os.environ.get("AGENT1_PGPASSWORD") or ""
    url=f"postgresql://{user}:{pw}@{host}:{port}/{db}"

with psycopg.connect(url, row_factory=dict_row) as conn:
    cur=conn.cursor()
    cur.execute("SELECT status, COUNT(*)::int n FROM jobs GROUP BY status ORDER BY n DESC")
    print("JOBS", cur.fetchall())
    cur.execute("SELECT day::text, status, counts FROM ingest_snapshots ORDER BY day DESC LIMIT 4")
    print("INGEST", cur.fetchall())
    cur.execute("""
      SELECT day::text,
             COUNT(*)::int n,
             ROUND(COALESCE(SUM(cost_usd),0)::numeric,4) cost,
             COALESCE(SUM(total_tokens),0)::bigint tok
      FROM vision_usage GROUP BY day ORDER BY day DESC LIMIT 5
    """)
    print("VISION_USAGE", cur.fetchall())
    cur.execute("SELECT MAX(day)::text AS d FROM agent_decisions")
    day = cur.fetchone()["d"]
    print("LATEST_DECISION_DAY", day)
    cur.execute("""
      SELECT itog, COUNT(*)::int n FROM agent_decisions
      WHERE day=%s::date GROUP BY itog ORDER BY n DESC
    """, (day,))
    print("ITOG", cur.fetchall())
    cur.execute("""
      SELECT COALESCE(stage2->>'status','null') st, COUNT(*)::int n
      FROM agent_decisions WHERE day=%s::date
      GROUP BY 1 ORDER BY n DESC
    """, (day,))
    print("STAGE2_STATUS", cur.fetchall())
    cur.execute("""
      SELECT COALESCE(stage2->>'reason','') reason, COUNT(*)::int n
      FROM agent_decisions
      WHERE day=%s::date AND COALESCE(stage2->>'status','') <> 'ok'
      GROUP BY 1 ORDER BY n DESC LIMIT 15
    """, (day,))
    print("NON_OK_REASONS", cur.fetchall())
    cur.execute("""
      SELECT COUNT(*)::int AS n FROM agent_decisions
      WHERE day=%s::date AND itog='К ЧЕЛОВЕКУ'
        AND (pometki ILIKE '%%не посмотр%%' OR pometki ILIKE '%%Stage2%%'
             OR COALESCE(stage2->>'status','') IN ('blind','vision_error','no_photos','deferred'))
    """, (day,))
    print("HUMAN_LIKELY_NO_VISION", cur.fetchone())
    cur.execute("""
      SELECT created_at::text, order_id, itog,
             stage2->>'status' st, stage2->>'reason' reason,
             left(coalesce(za_chto,''),60) za,
             left(coalesce(pometki,''),80) p
      FROM agent_decisions ORDER BY created_at DESC LIMIT 12
    """)
    print("LAST_DECISIONS")
    for r in cur.fetchall():
        print(r)
    cur.execute("""
      SELECT COUNT(*)::int queued FROM jobs WHERE status='queued'
    """)
    print("QUEUED", cur.fetchone())
    # env flags without leaking key
    print("VISION_ENABLED", os.environ.get("AGENT1_VISION_ENABLED"))
    print("VISION_MODEL", os.environ.get("AGENT1_VISION_MODEL"))
    print("VISION_URL", os.environ.get("AGENT1_VISION_URL"))
    key=os.environ.get("AGENT1_VISION_API_KEY") or os.environ.get("OPENAI_API_KEY") or ""
    print("VISION_KEY_SET", bool(key), "len", len(key), "suffix", key[-4:] if key else "")
PY

echo "=== 429 COUNT SINCE MIDNIGHT ==="
journalctl -u agent1-worker --since "2026-08-05 00:00" --no-pager | grep -c 'vision 429' || true
journalctl -u agent1-worker --since "2026-08-05 00:00" --no-pager | grep -iE 'insufficient|billing|quota|credit|payment|401|403|invalid.?api' | tail -20 || true
echo "=== LAST WORKER LINES ==="
journalctl -u agent1-worker -n 20 --no-pager
echo DONE
