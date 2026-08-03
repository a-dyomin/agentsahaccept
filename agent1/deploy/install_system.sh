#!/bin/bash
# Install nginx site + systemd units for agent1 only. Does NOT touch demosah.
set -euo pipefail
PASS="${1:?sudo password required as arg1}"

echo "$PASS" | sudo -S cp /home/admin-akea/agent1/deploy/nginx-agent1.conf /etc/nginx/sites-available/agent1.conf
echo "$PASS" | sudo -S ln -sfn /etc/nginx/sites-available/agent1.conf /etc/nginx/sites-enabled/agent1.conf
echo "$PASS" | sudo -S nginx -t
echo "$PASS" | sudo -S systemctl reload nginx

echo "$PASS" | sudo -S cp /home/admin-akea/agent1/deploy/agent1-api.service /etc/systemd/system/agent1-api.service
echo "$PASS" | sudo -S cp /home/admin-akea/agent1/deploy/agent1-worker.service /etc/systemd/system/agent1-worker.service
echo "$PASS" | sudo -S systemctl daemon-reload
echo "$PASS" | sudo -S systemctl enable --now agent1-api.service
echo "$PASS" | sudo -S systemctl enable --now agent1-worker.service
echo "$PASS" | sudo -S systemctl restart agent1-api.service agent1-worker.service
echo "$PASS" | sudo -S systemctl --no-pager --full status agent1-api.service agent1-worker.service | head -40
echo OK
