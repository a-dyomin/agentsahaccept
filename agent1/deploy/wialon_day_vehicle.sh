#!/bin/bash
set +e
ssh -i ~/.ssh/greta_ro -p 34023 -o IdentitiesOnly=yes -o BatchMode=yes gretaadmin@greta.akea-ds.ru \
  'kill 4011541 2>/dev/null; true'
ssh -i ~/.ssh/greta_ro -p 34023 -o IdentitiesOnly=yes -o BatchMode=yes gretaadmin@greta.akea-ds.ru \
  'cat > ~/agent1_export/wialon_day_vehicle.rb <<'"'"'RUBY'"'"'
day = Date.parse("2026-07-12")
from_ts = day.beginning_of_day.to_i
to_ts = (day + 1).beginning_of_day.to_i
puts({tz: Time.zone.name, from_ts: from_ts, to_ts: to_ts, bod: day.beginning_of_day.to_s}.inspect)

# pick up to 5 vehicles that actually worked that day
vids = Order.kept.where(date: day).where.not(schedule_id: nil).limit(200).filter_map { |o| o.schedule&.vehicle_id }.uniq.first(30)
vs = Vehicle.kept.where(id: vids).where.not(wialon_id: [nil, ""]).limit(5)
puts "candidates=#{vs.map { |v| [v.id, v.license_plate, v.wialon_id] }.inspect}"
w = Wialon::Service.new
vs.each do |v|
  ok, res = w.tracks_by_interval([{ id: v.wialon_id.to_i, time_from: from_ts, time_to: to_ts, schedule_id: nil }])
  n = res && res.values.first && res.values.first.size
  sample = res && res.values.first && res.values.first[0]
  puts({vid: v.id, wid: v.wialon_id, ok: ok, points: n, sample_at: sample && sample[:at]}.inspect)
end
# also try last_track now
v = vs.first
if v
  lt = w.last_track(v.wialon_id.to_i)
  puts({last_track: lt}.inspect)
end
puts "WIALON_DAY_OK"
RUBY
cd ~/greta-backend/current && export PATH=$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH && eval "$(rbenv init -)" && RAILS_ENV=production bundle exec rails runner ~/agent1_export/wialon_day_vehicle.rb'
