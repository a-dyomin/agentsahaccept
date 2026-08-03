#!/bin/bash
# Deploy vision + dashboard + D-2 timer. Usage: bash deploy_vision_ui.sh <sudo_password>
set -euo pipefail
PASS="${1:?sudo password}"
A1=/home/admin-akea/agent1

cd "$A1"
./venv/bin/pip install -q -r app/requirements.txt

# Vision flags (key set separately; do not clobber if already set with value)
touch "$A1/.env"
chmod 600 "$A1/.env"
grep -q '^AGENT1_STAGE2=' "$A1/.env" || echo 'AGENT1_STAGE2=1' >> "$A1/.env"
grep -q '^AGENT1_VISION_ENABLED=' "$A1/.env" || echo 'AGENT1_VISION_ENABLED=auto' >> "$A1/.env"
grep -q '^AGENT1_VISION_MODEL=' "$A1/.env" || echo 'AGENT1_VISION_MODEL=gpt-4o-mini' >> "$A1/.env"
grep -q '^AGENT1_VISION_INPUT_USD_PER_M=' "$A1/.env" || echo 'AGENT1_VISION_INPUT_USD_PER_M=0.15' >> "$A1/.env"
grep -q '^AGENT1_VISION_OUTPUT_USD_PER_M=' "$A1/.env" || echo 'AGENT1_VISION_OUTPUT_USD_PER_M=0.60' >> "$A1/.env"

echo "$PASS" | sudo -S cp "$A1/deploy/agent1-daily.service" /etc/systemd/system/agent1-daily.service
echo "$PASS" | sudo -S cp "$A1/deploy/agent1-daily.timer" /etc/systemd/system/agent1-daily.timer
echo "$PASS" | sudo -S systemctl daemon-reload
echo "$PASS" | sudo -S systemctl enable --now agent1-daily.timer
echo "$PASS" | sudo -S systemctl restart agent1-api agent1-worker
sleep 2
curl -sS 'http://127.0.0.1:8101/api/health'; echo
curl -sS 'http://127.0.0.1:8101/api/status?day=2026-07-12' | python3 -c 'import sys,json;d=json.load(sys.stdin);print("filter",d.get("filter"));print("costs",d.get("costs"));print("vision_enabled_probe_ok")'
systemctl list-timers agent1-daily.timer --no-pager | head -5
echo DEPLOY_VISION_UI_OK
