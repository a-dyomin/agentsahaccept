#!/bin/bash
# Deploy S3/Stage2 env + updated exporter/app to izhon.
# Usage: bash deploy_continue.sh <sudo_password>
set -euo pipefail
PASS="${1:?sudo password}"
A1=/home/admin-akea/agent1
HOME_A=/home/admin-akea

cd "$A1"
./venv/bin/pip install -q -r app/requirements.txt

touch "$A1/.env"
chmod 600 "$A1/.env"

# S3 keys — set if empty (values passed via env from caller)
upsert() {
  local key="$1" val="$2"
  if grep -q "^${key}=" "$A1/.env" 2>/dev/null; then
    # only fill if currently empty
    local cur
    cur=$(grep "^${key}=" "$A1/.env" | head -1 | cut -d= -f2-)
    if [ -z "$cur" ] && [ -n "$val" ]; then
      sed -i "s|^${key}=.*|${key}=${val}|" "$A1/.env"
    fi
  else
    echo "${key}=${val}" >> "$A1/.env"
  fi
}

upsert S3_ENDPOINT_URL "${S3_ENDPOINT_URL:-https://s3.ru-1.storage.selcloud.ru}"
upsert S3_REGION "${S3_REGION:-ru-1}"
upsert S3_BUCKET "${S3_BUCKET:-main}"
upsert S3_ACCESS_KEY "${S3_ACCESS_KEY:-}"
upsert S3_SECRET_KEY "${S3_SECRET_KEY:-}"
upsert S3_VERIFY_SSL "${S3_VERIFY_SSL:-false}"
upsert AGENT1_PHOTO_CACHE "${AGENT1_PHOTO_CACHE:-/home/admin-akea/agent1/data/photos}"
upsert AGENT1_STAGE2 "${AGENT1_STAGE2:-1}"
upsert AGENT1_VISION_ENABLED "${AGENT1_VISION_ENABLED:-auto}"
# clear stuck ingesting state on next boot via empty limit
upsert GRETA_EXPORT_LIMIT "${GRETA_EXPORT_LIMIT:-}"

mkdir -p "$A1/data/photos"

# Greta exporter
scp -i "$HOME_A/.ssh/greta_ro" -P 34023 -o IdentitiesOnly=yes -o BatchMode=yes \
  "$A1/greta/export_day.rb" gretaadmin@greta.akea-ds.ru:~/agent1_export/export_day.rb

echo "$PASS" | sudo -S systemctl restart agent1-api agent1-worker
sleep 2
curl -sS http://127.0.0.1:8101/api/health; echo
curl -sS http://127.0.0.1:8101/api/s3/smoke || true
echo
echo DEPLOY_CONTINUE_OK
