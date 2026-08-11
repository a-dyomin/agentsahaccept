#!/bin/bash
# Wipe Agent1 data + photo cache for clean prod start.
# Usage: bash wipe_for_prod.sh <sudo_password>
set -euo pipefail
PASS="${1:?sudo password}"
A1=/home/admin-akea/agent1

echo "=== disk before ==="
df -h / | tail -1
du -sh "$A1/data" 2>/dev/null || true

echo "$PASS" | sudo -S systemctl stop agent1-worker || true
# keep api up for health, or stop both briefly
echo "$PASS" | sudo -S systemctl stop agent1-api || true

cd "$A1"
set -a; . ./.env; set +a
PYTHONPATH=app ./venv/bin/python /tmp/tmp_wipe_agent1_db.py

# photo cache + any tmp exports
rm -rf "$A1/data/photos"/* 2>/dev/null || true
rm -rf /tmp/greta_day_* 2>/dev/null || true
find /tmp -maxdepth 1 -name 'agent1*' -type d -exec rm -rf {} + 2>/dev/null || true

# vacuum to reclaim space
./venv/bin/python - <<'PY'
import os, psycopg
url=os.environ["AGENT1_DATABASE_URL"]
# VACUUM FULL needs exclusive lock; DB is idle with services stopped
with psycopg.connect(url, autocommit=True) as conn:
    conn.execute("VACUUM FULL")
    size=conn.execute("SELECT pg_size_pretty(pg_database_size(current_database()))").fetchone()[0]
    print("vacuum_done db_size", size)
PY

echo "$PASS" | sudo -S systemctl start agent1-api agent1-worker
sleep 2
systemctl is-active agent1-api agent1-worker
curl -sS --noproxy '*' http://127.0.0.1:8101/api/health; echo
curl -sS --noproxy '*' 'http://127.0.0.1:8101/api/status' | python3 -c 'import sys,json;d=json.load(sys.stdin);print({k:d.get(k) for k in ("counts","costs","available_days","agent_state","last_ingest","active_run")})'

echo "=== timer ==="
systemctl list-timers agent1-daily.timer --no-pager | head -5
systemctl cat agent1-daily.service | grep -E 'ExecStart|Description' | head -5

echo "=== disk after ==="
df -h / | tail -1
du -sh "$A1/data" 2>/dev/null || true
echo PROD_WIPE_OK
