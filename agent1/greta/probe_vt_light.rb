# frozen_string_literal: true
# Light probe — no full-table COUNT
day = Date.parse(ARGV[0] || "2026-07-12")
from_ts = day.beginning_of_day.to_i
to_ts = (day + 1).beginning_of_day.to_i
puts({ day: day.to_s, tz: Time.zone.name, from_ts: from_ts, to_ts: to_ts }.inspect)
puts "cols=#{VehicleTracking.column_names.inspect}"

vid = nil
Order.kept.where(date: day).where.not(schedule_id: nil).limit(50).each do |o|
  vid = o.schedule&.vehicle_id
  break if vid
end
puts "sample_vid=#{vid}"
raise "no vehicle" unless vid

latest = ActiveRecord::Base.connection.exec_query(
  "SELECT id, vehicle_id, time, speed, ST_AsText(lonlat::geometry) AS geo FROM vehicle_trackings WHERE vehicle_id=#{vid.to_i} ORDER BY time DESC LIMIT 3"
)
puts "recent=#{latest.rows.inspect}"

unix = ActiveRecord::Base.connection.select_value(
  "SELECT COUNT(*) FROM vehicle_trackings WHERE vehicle_id=#{vid.to_i} AND time >= #{from_ts} AND time < #{to_ts}"
)
ms = ActiveRecord::Base.connection.select_value(
  "SELECT COUNT(*) FROM vehicle_trackings WHERE vehicle_id=#{vid.to_i} AND time >= #{from_ts * 1000} AND time < #{to_ts * 1000}"
)
puts "sql_unix_count=#{unix}"
puts "sql_ms_count=#{ms}"

all_unix = ActiveRecord::Base.connection.select_value(
  "SELECT COUNT(*) FROM vehicle_trackings WHERE time >= #{from_ts} AND time < #{to_ts}"
)
all_ms = ActiveRecord::Base.connection.select_value(
  "SELECT COUNT(*) FROM vehicle_trackings WHERE time >= #{from_ts * 1000} AND time < #{to_ts * 1000}"
)
puts "sql_all_unix=#{all_unix}"
puts "sql_all_ms=#{all_ms}"

geo = ActiveRecord::Base.connection.exec_query(
  "SELECT time, speed, ST_X(lonlat::geometry) AS lon, ST_Y(lonlat::geometry) AS lat FROM vehicle_trackings WHERE vehicle_id=#{vid.to_i} AND time >= #{from_ts} AND time < #{to_ts} AND lonlat IS NOT NULL LIMIT 3"
) rescue nil
if geo
  puts "geo_unix=#{geo.rows.inspect}"
else
  puts "geo_unix_err"
end

geo_ms = ActiveRecord::Base.connection.exec_query(
  "SELECT time, speed, ST_X(lonlat::geometry) AS lon, ST_Y(lonlat::geometry) AS lat FROM vehicle_trackings WHERE vehicle_id=#{vid.to_i} AND time >= #{from_ts * 1000} AND time < #{to_ts * 1000} AND lonlat IS NOT NULL LIMIT 3"
) rescue nil
puts "geo_ms=#{geo_ms&.rows.inspect}"
puts "PROBE_OK"
