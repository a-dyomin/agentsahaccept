#!/bin/bash
# Usage: bash smoke_wialon_ingest.sh <sudo_password> [day] [limit]
set -euo pipefail
PASS="${1:?sudo password}"
DAY="${2:-2026-07-12}"
LIMIT="${3:-20}"
echo "smoke ingest day=$DAY limit=$LIMIT"
if grep -q '^GRETA_EXPORT_LIMIT=' ~/agent1/.env; then
  sed -i "s/^GRETA_EXPORT_LIMIT=.*/GRETA_EXPORT_LIMIT=$LIMIT/" ~/agent1/.env
else
  echo "GRETA_EXPORT_LIMIT=$LIMIT" >> ~/agent1/.env
fi
echo "$PASS" | sudo -S systemctl restart agent1-api
sleep 2
curl -sS --max-time 900 -X POST "http://127.0.0.1:8101/api/ingest/day/${DAY}/sync?enqueue=true"
echo
sleep 3
curl -sS "http://127.0.0.1:8101/api/accept/day/${DAY}" || true
echo
sed -i 's/^GRETA_EXPORT_LIMIT=.*/GRETA_EXPORT_LIMIT=/' ~/agent1/.env
echo "$PASS" | sudo -S systemctl restart agent1-api
echo SMOKE_WIALON_DONE
