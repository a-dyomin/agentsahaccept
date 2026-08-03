#!/bin/bash
set -euo pipefail
scp -i ~/.ssh/greta_ro -P 34023 -o IdentitiesOnly=yes /tmp/probe_vt_day.rb gretaadmin@greta.akea-ds.ru:~/agent1_export/probe_vt_day.rb
ssh -i ~/.ssh/greta_ro -p 34023 -o IdentitiesOnly=yes -o BatchMode=yes gretaadmin@greta.akea-ds.ru \
  'cd ~/greta-backend/current && export PATH=$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH && eval "$(rbenv init -)" && RAILS_ENV=production bundle exec rails runner ~/agent1_export/probe_vt_day.rb 2026-07-12'
