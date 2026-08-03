#!/bin/bash
set +e
ssh -i ~/.ssh/greta_ro -p 34023 -o IdentitiesOnly=yes -o BatchMode=yes gretaadmin@greta.akea-ds.ru \
  'pgrep -af rails | head -30; pgrep -af wialon | head -20'
echo "==== write simple probe ===="
ssh -i ~/.ssh/greta_ro -p 34023 -o IdentitiesOnly=yes -o BatchMode=yes gretaadmin@greta.akea-ds.ru \
  'cat > ~/agent1_export/wialon_simple.rb <<'"'"'RUBY'"'"'
day = Date.parse("2026-07-12")
from_ts = day.beginning_of_day.to_i
to_ts = (day + 1).beginning_of_day.to_i
v = Vehicle.kept.where.not(wialon_id: [nil, ""]).limit(1).first
puts({vid: v&.id, plate: v&.license_plate, wid: v&.wialon_id}.inspect)
raise "no vehicle" unless v
w = Wialon::Service.new
ok, res = w.tracks_by_interval([{ id: v.wialon_id.to_i, time_from: from_ts, time_to: to_ts, schedule_id: nil }])
n = res && res.values.first && res.values.first.size
puts({ok: ok, points: n, keys: res && res.keys}.inspect)
puts "WIALON_SIMPLE_OK"
RUBY
cd ~/greta-backend/current && export PATH=$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH && eval "$(rbenv init -)" && RAILS_ENV=production bundle exec rails runner ~/agent1_export/wialon_simple.rb'
