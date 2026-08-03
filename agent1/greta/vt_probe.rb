#!/usr/bin/env ruby
# frozen_string_literal: true
# Tiny VehicleTracking probe — LIMIT 1 only, no COUNT(*)

puts "tz=#{Time.zone.name} now=#{Time.zone.now}"
d = Date.parse("2026-07-12")
from = d.beginning_of_day.to_i
to = (d + 1).beginning_of_day.to_i
puts "from=#{from} to=#{to} bod=#{d.beginning_of_day.inspect}"

vid = ActiveRecord::Base.connection.select_value(<<~SQL)
  SELECT s.vehicle_id
  FROM orders o
  JOIN schedules s ON s.id = o.schedule_id
  WHERE o.date = '2026-07-12'
    AND o.discarded_at IS NULL
    AND o.schedule_id IS NOT NULL
  LIMIT 1
SQL
puts "vid=#{vid.inspect}"
exit 0 if vid.nil?

conn = ActiveRecord::Base.connection
latest = conn.select_one(<<~SQL)
  SELECT id, vehicle_id, time, speed,
         ST_X(lonlat::geometry) AS lon,
         ST_Y(lonlat::geometry) AS lat
  FROM vehicle_trackings
  WHERE vehicle_id = #{vid.to_i}
  ORDER BY id DESC
  LIMIT 1
SQL
puts "latest=#{latest.inspect}"

day_hit = conn.select_one(<<~SQL)
  SELECT id, time, speed,
         ST_X(lonlat::geometry) AS lon,
         ST_Y(lonlat::geometry) AS lat
  FROM vehicle_trackings
  WHERE vehicle_id = #{vid.to_i}
    AND time >= #{from}
    AND time < #{to}
  LIMIT 1
SQL
puts "day_hit=#{day_hit.inspect}"

wide = conn.select_one(<<~SQL)
  SELECT id, time, speed,
         ST_X(lonlat::geometry) AS lon,
         ST_Y(lonlat::geometry) AS lat
  FROM vehicle_trackings
  WHERE vehicle_id = #{vid.to_i}
    AND time >= #{from - 12 * 3600}
    AND time < #{to + 12 * 3600}
  LIMIT 1
SQL
puts "wide_hit=#{wide.inspect}"

t = VehicleTracking.where(vehicle_id: vid).order(id: :desc).limit(1).first
coords = begin
  t&.lonlat&.coordinates
rescue StandardError => e
  "ERR:#{e.class}:#{e.message}"
end
puts "ar time=#{t&.time} coords=#{coords.inspect} class=#{t&.lonlat.class}"
