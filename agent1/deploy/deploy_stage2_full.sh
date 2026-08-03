#!/bin/bash
# Deploy track-fix export + S3/Stage2 env on izhon. Args: sudo_pass s3_key s3_secret
set -euo pipefail
PASS="${1:?sudo password}"
S3_KEY="${2:?s3 access key}"
S3_SECRET="${3:?s3 secret}"
A1=/home/admin-akea/agent1
HOME_A=/home/admin-akea

cd "$A1"
./venv/bin/pip install -q -r app/requirements.txt

touch "$A1/.env"
chmod 600 "$A1/.env"

set_env() {
  local k="$1" v="$2"
  if grep -q "^${k}=" "$A1/.env" 2>/dev/null; then
    # escape sed specials in v minimally
    python3 - "$A1/.env" "$k" "$v" <<'PY'
import sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path, encoding="utf-8").read().splitlines()
out, found = [], False
for line in lines:
    if line.startswith(key + "="):
        out.append(f"{key}={val}")
        found = True
    else:
        out.append(line)
if not found:
    out.append(f"{key}={val}")
open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
  else
    printf '%s=%s\n' "$k" "$v" >> "$A1/.env"
  fi
}

set_env S3_ENDPOINT_URL "https://s3.ru-1.storage.selcloud.ru"
set_env S3_REGION "ru-1"
set_env S3_BUCKET "main"
set_env S3_ACCESS_KEY "$S3_KEY"
set_env S3_SECRET_KEY "$S3_SECRET"
set_env S3_VERIFY_SSL "false"
set_env AGENT1_PHOTO_CACHE "/home/admin-akea/agent1/data/photos"
set_env AGENT1_STAGE2 "1"
set_env AGENT1_VISION_ENABLED "auto"
# clear smoke limit
set_env GRETA_EXPORT_LIMIT ""

mkdir -p "$A1/data/photos"

# upload exporter to Greta
scp -i "$HOME_A/.ssh/greta_ro" -P 34023 -o IdentitiesOnly=yes -o BatchMode=yes \
  "$A1/greta/export_day.rb" gretaadmin@greta.akea-ds.ru:~/agent1_export/export_day.rb

# reset stuck ingesting state via API after restart
echo "$PASS" | sudo -S systemctl restart agent1-api agent1-worker
sleep 3
curl -sS http://127.0.0.1:8101/api/health; echo
curl -sS http://127.0.0.1:8101/api/s3/smoke || true
echo
echo DEPLOY_STAGE2_OK
