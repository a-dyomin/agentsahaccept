# frozen_string_literal: true
# Light probe — no full-table COUNT. Usage: rails runner probe_tracks_day_light.rb 2026-07-12
day = Date.parse(ARGV[0] || "2026-07-12")
from_ts = day.beginning_of_day.to_i
to_ts = (day + 1).beginning_of_day.to_i
puts "day=#{day} tz=#{Time.zone.name} from=#{from_ts} to=#{to_ts}"

vid = ActiveRecord::Base.connection.select_value(<<~SQL)
  SELECT s.vehicle_id
  FROM orders o
  INNER JOIN schedules s ON s.id = o.schedule_id
  WHERE o.date = '#{day}' AND o.discarded_at IS NULL AND s.vehicle_id IS NOT NULL
  LIMIT 1
SQL
puts "sample_vid=#{vid.inspect}"
abort("no vehicle") unless vid

conn = ActiveRecord::Base.connection
latest = conn.select_one("SELECT id, vehicle_id, time, speed, lonlat IS NOT NULL AS has_ll FROM vehicle_trackings WHERE vehicle_id=#{vid.to_i} ORDER BY time DESC LIMIT 1")
puts "latest=#{latest.inspect}"

[
  ["unix", from_ts, to_ts],
  ["ms", from_ts * 1000, to_ts * 1000],
].each do |label, a, b|
  n = conn.select_value("SELECT COUNT(*) FROM vehicle_trackings WHERE vehicle_id=#{vid.to_i} AND time >= #{a} AND time < #{b}")
  puts "count_#{label}=#{n}"
end

begin
  rows = conn.exec_query(<<~SQL).rows
    SELECT time, speed, ST_X(lonlat::geometry), ST_Y(lonlat::geometry)
    FROM vehicle_trackings
    WHERE vehicle_id=#{vid.to_i} AND time >= #{from_ts} AND time < #{to_ts} AND lonlat IS NOT NULL
    LIMIT 3
  SQL
  puts "geo_unix=#{rows.inspect}"
rescue StandardError => e
  puts "geo_unix_err=#{e.class}:#{e.message}"
end

begin
  rows = conn.exec_query(<<~SQL).rows
    SELECT time, speed, ST_X(lonlat::geometry), ST_Y(lonlat::geometry)
    FROM vehicle_trackings
    WHERE vehicle_id=#{vid.to_i} AND time >= #{from_ts * 1000} AND time < #{to_ts * 1000} AND lonlat IS NOT NULL
    LIMIT 3
  SQL
  puts "geo_ms=#{rows.inspect}"
rescue StandardError => e
  puts "geo_ms_err=#{e.class}:#{e.message}"
end

n_all = conn.select_value("SELECT COUNT(*) FROM vehicle_trackings WHERE time >= #{from_ts} AND time < #{to_ts}")
n_all_ms = conn.select_value("SELECT COUNT(*) FROM vehicle_trackings WHERE time >= #{from_ts * 1000} AND time < #{to_ts * 1000}")
puts "all_vehicles_unix=#{n_all} all_vehicles_ms=#{n_all_ms}"
puts "LIGHT_PROBE_OK"
