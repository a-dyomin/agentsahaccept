#!/bin/bash
set -euo pipefail
# Probe Wialon::Service for one vehicle on 2026-07-12 (no vehicle_trackings)
ssh -i ~/.ssh/greta_ro -p 34023 -o IdentitiesOnly=yes -o BatchMode=yes gretaadmin@greta.akea-ds.ru bash -s <<'REMOTE'
set -euo pipefail
cd ~/greta-backend/current
export PATH=$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH
eval "$(rbenv init -)"
cat > /tmp/wialon_smoke.rb <<'RUBY'
day = Date.parse("2026-07-12")
from_ts = day.beginning_of_day.to_i
to_ts = (day + 1).beginning_of_day.to_i
o = Order.kept.where(date: day).where.not(schedule_id: nil).joins("INNER JOIN schedules ON schedules.id = orders.schedule_id INNER JOIN vehicles ON vehicles.id = schedules.vehicle_id").where("vehicles.wialon_id IS NOT NULL").where("EXISTS (SELECT 1 FROM photos WHERE photos.order_id = orders.id AND photos.discarded_at IS NULL)").limit(1).first
raise "no order" unless o
v = o.schedule.vehicle
puts({order_id: o.id, state: o.state, vehicle_id: v.id, plate: v.license_plate, wialon_id: v.wialon_id, photos: o.photos.kept.count}.inspect)
w = Wialon::Service.new
ok, res = w.tracks_by_interval([{ id: v.wialon_id.to_i, time_from: from_ts, time_to: to_ts, schedule_id: o.schedule_id }])
puts({ok: ok, keys: res && res.keys, points: res && res.values.first&.size}.inspect)
if res && res.values.first && res.values.first[0]
  p0 = res.values.first[0]
  puts({sample: {lat: p0[:lat], lon: p0[:lon], at: p0[:at], speed: p0[:speed]}}.inspect)
end
puts "WIALON_SMOKE_OK"
RUBY
RAILS_ENV=production bundle exec rails runner /tmp/wialon_smoke.rb
REMOTE
