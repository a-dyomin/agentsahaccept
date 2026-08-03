#!/bin/bash
# Install Greta SSH key on izhon + export script on Greta + restart agent1
set -euo pipefail
PASS="${1:?sudo password}"

# --- on this host (izhon) we expect files already uploaded ---
chmod 600 /home/admin-akea/.ssh/greta_ro
chmod 644 /home/admin-akea/.ssh/greta_ro.pub || true

# ensure env
grep -q GRETA_SSH_KEY /home/admin-akea/agent1/.env 2>/dev/null || cat >> /home/admin-akea/agent1/.env <<'EOF'
GRETA_SSH_HOST=greta.akea-ds.ru
GRETA_SSH_PORT=34023
GRETA_SSH_USER=gretaadmin
GRETA_SSH_KEY=/home/admin-akea/.ssh/greta_ro
GRETA_EXPORT_SCRIPT=/home/gretaadmin/agent1_export/export_day.rb
GRETA_BACKEND=/home/gretaadmin/greta-backend/current
EOF

cd /home/admin-akea/agent1
./venv/bin/pip install -q -r app/requirements.txt

# accept greta host key
ssh -i /home/admin-akea/.ssh/greta_ro -p 34023 -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o IdentitiesOnly=yes gretaadmin@greta.akea-ds.ru 'mkdir -p ~/agent1_export && echo GRETA_SSH_OK'

echo "$PASS" | sudo -S systemctl restart agent1-api agent1-worker
sleep 2
echo "$PASS" | sudo -S systemctl is-active agent1-api agent1-worker
curl -sS http://127.0.0.1:8101/api/health; echo
echo READY
