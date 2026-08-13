#!/bin/bash
# Usage: bash _stop_agent_sudo.sh '<sudo-password>'
set -e
PASS="${1:?sudo password required}"

echo "$PASS" | sudo -S systemctl stop agent1-worker
echo "$PASS" | sudo -S systemctl disable --now agent1-daily.timer

systemctl is-active agent1-api agent1-worker agent1-daily.timer || true
systemctl is-enabled agent1-daily.timer || true
pgrep -af worker.py || echo no_worker
echo STOP_SUDO_OK
