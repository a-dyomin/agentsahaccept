#!/bin/bash
set -euo pipefail
# drop leftover probe ssh from izhon
pkill -f 'probe_vt' 2>/dev/null || true
pkill -f 'rails runner ~/agent1_export' 2>/dev/null || true
sleep 1

# ensure exporter probe uses sync stdout
cat > /tmp/vt_light_run.rb <<'RUBY'
STDOUT.sync = true
STDERR.sync = true
load "/home/gretaadmin/agent1_export/vt_light.rb"
RUBY

scp -i ~/.ssh/greta_ro -P 34023 -o IdentitiesOnly=yes -o BatchMode=yes \
  /tmp/vt_light_run.rb gretaadmin@greta.akea-ds.ru:~/agent1_export/vt_light_run.rb

echo "=== START ==="
ssh -i ~/.ssh/greta_ro -p 34023 -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=20 \
  gretaadmin@greta.akea-ds.ru \
  'cd ~/greta-backend/current && export PATH=$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH && eval "$(rbenv init -)" && RAILS_ENV=production bundle exec rails runner ~/agent1_export/vt_light_run.rb'
echo "=== END ==="
