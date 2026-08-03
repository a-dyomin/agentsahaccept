#!/bin/bash
# Configure S3 + Stage2 on izhon and deploy updated exporter.
# Usage: bash deploy_stage2_fill.sh <sudo_password>
# Reads S3 keys from stdin as: ACCESS_KEY\nSECRET_KEY  OR from env S3_ACCESS_KEY/S3_SECRET_KEY.
set -euo pipefail
PASS="${1:?sudo password}"
A1=/home/admin-akea/agent1
HOME_A=/home/admin-akea

if [[ -z "${S3_ACCESS_KEY:-}" || -z "${S3_SECRET_KEY:-}" ]]; then
  echo "Set S3_ACCESS_KEY and S3_SECRET_KEY in env before running" >&2
  exit 1
fi

cd "$A1"
./venv/bin/pip install -q -r app/requirements.txt

touch "$A1/.env"
chmod 600 "$A1/.env"

upsert() {
  local key="$1" val="$2"
  if grep -q "^${key}=" "$A1/.env" 2>/dev/null; then
    # escape sed specials in val minimally
    local esc
    esc=$(printf '%s' "$val" | sed -e 's/[\/&]/\\&/g')
    sed -i "s/^${key}=.*/${key}=${esc}/" "$A1/.env"
  else
    printf '%s=%s\n' "$key" "$val" >> "$A1/.env"
  fi
}

upsert S3_ENDPOINT_URL "${S3_ENDPOINT_URL:-https://s3.ru-1.storage.selcloud.ru}"
upsert S3_REGION "${S3_REGION:-ru-1}"
upsert S3_BUCKET "${S3_BUCKET:-main}"
upsert S3_ACCESS_KEY "$S3_ACCESS_KEY"
upsert S3_SECRET_KEY "$S3_SECRET_KEY"
upsert S3_VERIFY_SSL "${S3_VERIFY_SSL:-false}"
upsert AGENT1_PHOTO_CACHE "${AGENT1_PHOTO_CACHE:-/home/admin-akea/agent1/data/photos}"
upsert AGENT1_STAGE2 "${AGENT1_STAGE2:-1}"
upsert AGENT1_VISION_ENABLED "${AGENT1_VISION_ENABLED:-auto}"

mkdir -p "$A1/data/photos"

# Greta exporter
scp -i "$HOME_A/.ssh/greta_ro" -P 34023 -o IdentitiesOnly=yes -o BatchMode=yes \
  "$A1/greta/export_day.rb" gretaadmin@greta.akea-ds.ru:~/agent1_export/export_day.rb

echo "$PASS" | sudo -S systemctl restart agent1-api agent1-worker
sleep 3
curl -sS http://127.0.0.1:8101/api/health; echo
curl -sS http://127.0.0.1:8101/api/s3/smoke; echo
echo DEPLOY_STAGE2_OK
