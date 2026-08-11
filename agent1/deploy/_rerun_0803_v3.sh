#!/bin/bash
set -eu
set -a
# shellcheck disable=SC1091
source /home/admin-akea/agent1/.env
set +a
cd /home/admin-akea/agent1/app
DAY=2026-08-03

echo "=== дочищаем jobs/results прошлого прогона ==="
../venv/bin/python <<'PY'
import os
import psycopg
from psycopg.rows import dict_row

url = next(
    os.environ[k]
    for k in ("DATABASE_URL", "AGENT1_DATABASE_URL", "AGENT1_DB_URL")
    if os.environ.get(k)
)
day = "2026-08-03"
with psycopg.connect(url, row_factory=dict_row) as conn:
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO events(ts, level, message) VALUES (NOW(),'info',%s)",
        (
            f"requeue {day}: кадры теперь помечены ДО/ПОСЛЕ (ptype), "
            "А4 и Н5 приведены к позитивной полярности",
        ),
    )
    cur.execute("SELECT id FROM runs WHERE day=%s", (day,))
    runs = [r["id"] for r in cur.fetchall()]
    print("  runs:", len(runs))
    if runs:
        cur.execute("DELETE FROM results WHERE run_id = ANY(%s)", (runs,))
        print("  results:", cur.rowcount)
        cur.execute("DELETE FROM jobs WHERE run_id = ANY(%s)", (runs,))
        print("  jobs:", cur.rowcount)
    for t in ("agent_decisions", "comparisons", "vision_usage"):
        cur.execute(f"DELETE FROM {t} WHERE day=%s::date", (day,))
        print(f"  {t}:", cur.rowcount)
    cur.execute(
        "UPDATE runs SET status='cancelled', finished_at=NOW() "
        "WHERE day=%s AND status<>'cancelled'",
        (day,),
    )
    print("  runs cancelled:", cur.rowcount)
    conn.commit()
PY

echo
echo "=== ставим $DAY в очередь заново ==="
../venv/bin/python <<'PY'
from ingest import enqueue_stage1

print("  RUN", enqueue_stage1("2026-08-03", note="rerun: ДО/ПОСЛЕ + полярность А4/Н5"))
PY

echo
echo "=== состояние через 30 с ==="
sleep 30
curl --noproxy '*' -sS -m 15 "http://127.0.0.1:8101/api/status?day_from=$DAY&day_to=$DAY" -o /tmp/st.json || true
../venv/bin/python <<'PY'
import json
try:
    d = json.load(open("/tmp/st.json"))
except Exception as exc:
    print("  статус недоступен:", exc)
else:
    c = d.get("counts", {})
    print("  состояние:", d.get("agent_state"))
    print("  очередь:", c.get("queued"), "в работе:", c.get("in_progress"),
          "готово:", c.get("processed"), "ошибок:", c.get("errors"))
    print("  фото-нарушения: по содержанию", c.get("photo_by_content"),
          "/ только ГЕО", c.get("photo_by_geo_only"))
PY
echo REQUEUE_OK
