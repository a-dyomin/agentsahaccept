#!/bin/bash
set -eu
set -a
# shellcheck disable=SC1091
source /home/admin-akea/agent1/.env
set +a
cd /home/admin-akea/agent1/app

echo "=== smoke: полярность О3 ==="
../venv/bin/python <<'PY'
from checklist_verdict import to_internal_answers, compute_photo_verdict
from checklist_prompts import questions_for

a = to_internal_answers({"О1":1,"О2":1,"О3":1,"А0":1,"А1":1,"А2":1,"А3":1,"А4":0,"А5":1})
assert a["О3"] == 0, a
r = compute_photo_verdict("1а", a)
assert r.photo_verdict == "ПОДТВЕРЖДЕНО", r
b = to_internal_answers({"О1":1,"О2":1,"О3":0,"А0":1})
assert b["О3"] == 1, b
assert "подлинные" in questions_for("1а")
print("SMOKE_OK")
PY

DAY=2026-08-03
echo "=== чистим день $DAY ==="
../venv/bin/python <<'PY'
import os
import psycopg
from psycopg.rows import dict_row

url = None
for k in ("DATABASE_URL", "AGENT1_DATABASE_URL", "AGENT1_DB_URL"):
    if os.environ.get(k):
        url = os.environ[k]
        break
if not url:
    url = (
        f"postgresql://{os.environ.get('PGUSER','agent1')}:"
        f"{os.environ.get('PGPASSWORD','')}@"
        f"{os.environ.get('PGHOST','127.0.0.1')}:"
        f"{os.environ.get('PGPORT','5432')}/"
        f"{os.environ.get('PGDATABASE','agent1')}"
    )

day = "2026-08-03"
with psycopg.connect(url, row_factory=dict_row) as conn:
    cur = conn.cursor()
    cur.execute(
        "SELECT COUNT(*)::int n, ROUND(COALESCE(SUM(cost_usd),0)::numeric,4) c "
        "FROM vision_usage WHERE day=%s::date",
        (day,),
    )
    spent = cur.fetchone()
    print("прежний прогон: vision_calls=%s cost=$%s" % (spent["n"], spent["c"]))
    cur.execute(
        "INSERT INTO events(ts, level, message) VALUES (NOW(),'info',%s)",
        (
            f"requeue {day}: сброшен прогон с перевёрнутым О3; "
            f"потрачено до сброса vision_calls={spent['n']} cost=${spent['c']}",
        ),
    )
    cur.execute("SELECT id FROM runs WHERE day=%s", (day,))
    runs = [r["id"] for r in cur.fetchall()]
    print("runs:", runs)
    if runs:
        cur.execute("DELETE FROM results WHERE run_id = ANY(%s)", (runs,))
        print("results deleted", cur.rowcount)
        cur.execute("DELETE FROM jobs WHERE run_id = ANY(%s)", (runs,))
        print("jobs deleted", cur.rowcount)
    cur.execute("DELETE FROM agent_decisions WHERE day=%s::date", (day,))
    print("agent_decisions deleted", cur.rowcount)
    cur.execute("DELETE FROM comparisons WHERE day=%s::date", (day,))
    print("comparisons deleted", cur.rowcount)
    cur.execute("DELETE FROM vision_usage WHERE day=%s::date", (day,))
    print("vision_usage deleted", cur.rowcount)
    cur.execute(
        "UPDATE runs SET status='cancelled', finished_at=NOW() WHERE day=%s AND status<>'cancelled'",
        (day,),
    )
    print("runs cancelled", cur.rowcount)
    conn.commit()
PY

echo "=== заново ставим в очередь $DAY ==="
../venv/bin/python <<'PY'
from ingest import enqueue_stage1
run = enqueue_stage1("2026-08-03", note="rerun after О3 polarity fix")
print("RUN", run)
PY

echo "=== состояние ==="
curl --noproxy '*' -sS -m 10 http://127.0.0.1:8101/api/status -o /tmp/st.json
../venv/bin/python -c "import json;d=json.load(open('/tmp/st.json'));print('state',d.get('agent_state'));print('counts',d.get('counts'));print('active_run',d.get('active_run'))"
echo REQUEUE_OK
