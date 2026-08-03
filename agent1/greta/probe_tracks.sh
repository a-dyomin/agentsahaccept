#!/bin/bash
# Diagnose VehicleTracking availability for a day
set -euo pipefail
DAY="${1:-2026-07-12}"
cd "$HOME/greta-backend/current"
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
eval "$(rbenv init -)"
RAILS_ENV=production bundle exec rails runner -
<<RUBY
d = Date.parse('$DAY')
from = d.beginning_of_day.to_i
to = (d+1).beginning_of_day.to_i
oids = Order.kept.where(date: d).where.not(schedule_id: nil).limit(5).pluck(:id, :schedule_id)
puts "sample_orders=#{oids.inspect}"
vids = Order.kept.where(date: d).joins("INNER JOIN schedules ON schedules.id = orders.schedule_id").distinct.pluck("schedules.vehicle_id").compact
puts "vehicles=#{vids.size}"
puts "trackings_day_any=#{VehicleTracking.where(time: from...to).limit(1).count}"
puts "trackings_for_vehicles=#{VehicleTracking.where(vehicle_id: vids.first(20), time: from...to).count}" if vids.any?
t = VehicleTracking.where(vehicle_id: vids.first, time: from...to).order(:time).first if vids.any?
if t
  puts "sample t=#{t.time} speed=#{t.speed} lonlat=#{t.lonlat.inspect}"
end
RUBY
