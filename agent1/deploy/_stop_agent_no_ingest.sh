#!/bin/bash
# Stop Agent1 processing and prevent new day ingest (12.08 code drop).
set -eu
set -a
# shellcheck disable=SC1091
source /home/admin-akea/agent1/.env
set +a

echo "=== stop worker + disable daily ingest timer ==="
if [ -n "${SUDO_PASS:-}" ]; then
  echo "$SUDO_PASS" | sudo -S systemctl stop agent1-worker || true
  echo "$SUDO_PASS" | sudo -S systemctl disable --now agent1-daily.timer || true
elif [ -n "${PASS:-}" ]; then
  echo "$PASS" | sudo -S systemctl stop agent1-worker || true
  echo "$PASS" | sudo -S systemctl disable --now agent1-daily.timer || true
else
  sudo -n systemctl stop agent1-worker || systemctl --user stop agent1-worker 2>/dev/null || true
  sudo -n systemctl disable --now agent1-daily.timer || true
fi

systemctl is-active agent1-api agent1-worker agent1-daily.timer 2>/dev/null || true
systemctl is-enabled agent1-daily.timer 2>/dev/null || true

echo
echo "=== cancel queued/leased jobs (all days); no new ingest ==="
cd /home/admin-akea/agent1/app
../venv/bin/python <<'PY'
import os
import psycopg
from psycopg.rows import dict_row

url = next(
    os.environ[k]
    for k in ("DATABASE_URL", "AGENT1_DATABASE_URL", "AGENT1_DB_URL")
    if os.environ.get(k)
)
with psycopg.connect(url, row_factory=dict_row) as conn:
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO events(ts, level, message) VALUES (NOW(),'info',%s)",
        (
            "stop agent: worker остановлен, daily.timer выключен; "
            "очередь очищена; новые даты не загружать до обновления кода 12.08",
        ),
    )
    cur.execute(
        "SELECT status, COUNT(*)::int n FROM jobs GROUP BY status ORDER BY n DESC"
    )
    print("jobs before:", cur.fetchall())
    cur.execute(
        "DELETE FROM jobs WHERE status IN ('queued','leased','error')"
    )
    print("jobs deleted (queued/leased/error):", cur.rowcount)
    cur.execute(
        "UPDATE runs SET status='cancelled', finished_at=NOW() "
        "WHERE status NOT IN ('cancelled','done','finished')"
    )
    print("runs cancelled:", cur.rowcount)
    try:
        cur.execute(
            "INSERT INTO meta(key,value) VALUES ('agent_state','paused') "
            "ON CONFLICT(key) DO UPDATE SET value=EXCLUDED.value"
        )
    except Exception as exc:  # noqa: BLE001
        print("meta agent_state skip:", exc)
    cur.execute(
        "SELECT status, COUNT(*)::int n FROM jobs GROUP BY status ORDER BY n DESC"
    )
    print("jobs after:", cur.fetchall())
    conn.commit()
PY

echo
curl --noproxy '*' -sS -m 10 http://127.0.0.1:8101/api/health || true
echo
echo STOP_AGENT_OK
