#!/bin/bash
# Deploy Wialon-track exporter + Stage2/S3/accept-test to izhon + Greta.
# Usage: bash deploy_wialon_tracks.sh <sudo_password>
set -euo pipefail
PASS="${1:?sudo password}"
A1=/home/admin-akea/agent1
HOME_A=/home/admin-akea

cd "$A1"
./venv/bin/pip install -q -r app/requirements.txt

touch "$A1/.env"
chmod 600 "$A1/.env"
# S3 + Stage2 env stubs (do not overwrite existing non-empty keys)
grep -q '^S3_ENDPOINT_URL=' "$A1/.env" 2>/dev/null || cat >> "$A1/.env" <<'EOF'
S3_ENDPOINT_URL=https://s3.ru-1.storage.selcloud.ru
S3_REGION=ru-1
S3_BUCKET=main
S3_ACCESS_KEY=
S3_SECRET_KEY=
S3_VERIFY_SSL=false
AGENT1_PHOTO_CACHE=/home/admin-akea/agent1/data/photos
AGENT1_STAGE2=1
AGENT1_VISION_ENABLED=auto
EOF

mkdir -p "$A1/data/photos"

# Greta exporter: Wialon only — no vehicle_trackings
scp -i "$HOME_A/.ssh/greta_ro" -P 34023 -o IdentitiesOnly=yes -o BatchMode=yes \
  "$A1/greta/export_day.rb" gretaadmin@greta.akea-ds.ru:~/agent1_export/export_day.rb || {
  echo "ERROR: failed to upload export_day.rb to Greta" >&2
  exit 1
}

echo "$PASS" | sudo -S systemctl restart agent1-api agent1-worker
sleep 2
curl -sS http://127.0.0.1:8101/api/health
echo
echo DEPLOY_WIALON_OK
