#!/bin/bash
set -euo pipefail
PASS='Pjke6rf@@123'
echo "$PASS" | sudo -S apt-get update -qq
echo "$PASS" | sudo -S DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3.13-venv python3-pip
cd /home/admin-akea/agent1
rm -rf venv
python3 -m venv venv
./venv/bin/pip install -q -U pip
./venv/bin/pip install -q -r app/requirements.txt
sed -i 's/\r$//' deploy/install_system.sh deploy/*.service || true
chmod +x deploy/install_system.sh
bash deploy/install_system.sh "$PASS"
# smoke
sleep 2
curl -sS http://127.0.0.1:8101/api/health || true
curl -sS -H 'Host: agent1.izhon.ru' http://127.0.0.1/api/health || true
echo DONE
