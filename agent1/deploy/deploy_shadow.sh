#!/bin/bash
# Full bring-up of Agent1 shadow on izhon + Greta exporter.
# Usage: bash deploy_shadow.sh <izhon_sudo_password>
set -euo pipefail
PASS="${1:?sudo password}"
HOME_A=/home/admin-akea
A1=$HOME_A/agent1

# 1) Greta key on izhon
install -m 600 "$A1/secrets/greta_ro" "$HOME_A/.ssh/greta_ro"
chmod 700 "$HOME_A/.ssh"

# 2) Env
touch "$A1/.env"
chmod 600 "$A1/.env"
grep -q '^GRETA_SSH_HOST=' "$A1/.env" 2>/dev/null || cat >> "$A1/.env" <<'EOF'
GRETA_SSH_HOST=greta.akea-ds.ru
GRETA_SSH_PORT=34023
GRETA_SSH_USER=gretaadmin
GRETA_SSH_KEY=/home/admin-akea/.ssh/greta_ro
GRETA_EXPORT_SCRIPT=/home/gretaadmin/agent1_export/export_day.rb
GRETA_BACKEND=/home/gretaadmin/greta-backend/current
GRETA_EXPORT_LIMIT=
EOF

# ensure DATABASE_URL already present from postgres migrate
grep -q AGENT1_DATABASE_URL "$A1/.env"

# 3) Python deps + schema
cd "$A1"
./venv/bin/pip install -q -r app/requirements.txt

# 4) SSH to Greta: upload export + test
ssh -i "$HOME_A/.ssh/greta_ro" -p 34023 -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o BatchMode=yes \
  gretaadmin@greta.akea-ds.ru 'mkdir -p ~/agent1_export && echo GRETA_OK'

scp -i "$HOME_A/.ssh/greta_ro" -P 34023 -o IdentitiesOnly=yes -o BatchMode=yes \
  "$A1/greta/export_day.rb" gretaadmin@greta.akea-ds.ru:~/agent1_export/export_day.rb

# 5) systemd units + timer
echo "$PASS" | sudo -S cp "$A1/deploy/agent1-api.service" /etc/systemd/system/agent1-api.service
echo "$PASS" | sudo -S cp "$A1/deploy/agent1-worker.service" /etc/systemd/system/agent1-worker.service
echo "$PASS" | sudo -S cp "$A1/deploy/agent1-daily.service" /etc/systemd/system/agent1-daily.service
echo "$PASS" | sudo -S cp "$A1/deploy/agent1-daily.timer" /etc/systemd/system/agent1-daily.timer

# rewrite api/worker units with EnvironmentFile if not already
echo "$PASS" | sudo -S tee /etc/systemd/system/agent1-api.service >/dev/null <<'EOF'
[Unit]
Description=Agent1 control plane (shadow)
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
User=admin-akea
WorkingDirectory=/home/admin-akea/agent1/app
EnvironmentFile=/home/admin-akea/agent1/.env
Environment=PATH=/home/admin-akea/agent1/venv/bin:/usr/bin
ExecStart=/home/admin-akea/agent1/venv/bin/uvicorn main:app --host 127.0.0.1 --port 8101
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

echo "$PASS" | sudo -S tee /etc/systemd/system/agent1-worker.service >/dev/null <<'EOF'
[Unit]
Description=Agent1 shadow worker
After=network.target agent1-api.service postgresql.service
Requires=agent1-api.service

[Service]
Type=simple
User=admin-akea
WorkingDirectory=/home/admin-akea/agent1/app
EnvironmentFile=/home/admin-akea/agent1/.env
Environment=AGENT1_API=http://127.0.0.1:8101
Environment=AGENT1_WORKER_ID=worker-1
Environment=PATH=/home/admin-akea/agent1/venv/bin:/usr/bin
ExecStart=/home/admin-akea/agent1/venv/bin/python worker.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

echo "$PASS" | sudo -S systemctl daemon-reload
echo "$PASS" | sudo -S systemctl enable --now agent1-api agent1-worker
echo "$PASS" | sudo -S systemctl enable --now agent1-daily.timer
echo "$PASS" | sudo -S systemctl restart agent1-api agent1-worker
sleep 2
curl -sS http://127.0.0.1:8101/api/health; echo
echo "$PASS" | sudo -S systemctl is-active agent1-api agent1-worker agent1-daily.timer
echo DEPLOY_OK
