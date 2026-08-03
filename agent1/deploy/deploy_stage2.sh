#!/bin/bash
# Deploy Stage2/S3/track-fix updates to izhon + Greta exporter.
# Usage: bash deploy_stage2.sh <sudo_password>
set -euo pipefail
PASS="${1:?sudo password}"
A1=/home/admin-akea/agent1
HOME_A=/home/admin-akea

cd "$A1"
./venv/bin/pip install -q -r app/requirements.txt

# S3 env keys (fill once; do not overwrite existing)
touch "$A1/.env"
chmod 600 "$A1/.env"
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

# Greta exporter with PostGIS track preload
scp -i "$HOME_A/.ssh/greta_ro" -P 34023 -o IdentitiesOnly=yes -o BatchMode=yes \
  "$A1/greta/export_day.rb" gretaadmin@greta.akea-ds.ru:~/agent1_export/export_day.rb

echo "$PASS" | sudo -S systemctl restart agent1-api agent1-worker
sleep 2
curl -sS http://127.0.0.1:8101/api/health
echo
curl -sS -H 'Host: agent1.izhon.ru' http://127.0.0.1/api/health || true
echo
echo DEPLOY_STAGE2_OK
