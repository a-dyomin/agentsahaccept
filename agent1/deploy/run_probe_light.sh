#!/bin/bash
set -euo pipefail
pkill -f probe_vt_light 2>/dev/null || true
pkill -f 'rails runner.*probe' 2>/dev/null || true
echo killed_local
ssh -i ~/.ssh/greta_ro -p 34023 -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=20 \
  gretaadmin@greta.akea-ds.ru 'echo GRETA_OK; hostname; ls -la ~/agent1_export/ | head'
echo "=== run light probe ==="
sed -i 's/\r$//' ~/agent1/greta/probe_vt_light.rb
scp -i ~/.ssh/greta_ro -P 34023 -o IdentitiesOnly=yes -o BatchMode=yes \
  ~/agent1/greta/probe_vt_light.rb gretaadmin@greta.akea-ds.ru:~/agent1_export/probe_vt_light.rb
ssh -i ~/.ssh/greta_ro -p 34023 -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=20 \
  gretaadmin@greta.akea-ds.ru \
  'cd ~/greta-backend/current && export PATH=$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH && eval "$(rbenv init -)" && RAILS_ENV=production bundle exec rails runner ~/agent1_export/probe_vt_light.rb 2026-07-12'
echo PROBE_DONE
