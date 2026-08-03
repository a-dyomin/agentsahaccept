# frozen_string_literal: true
# Probe VehicleTracking for a day — run via rails runner
day = Date.parse(ARGV[0] || "2026-07-12")
from_ts = day.beginning_of_day.to_i
to_ts = (day + 1).beginning_of_day.to_i
puts({
  day: day.to_s,
  tz: Time.zone.name,
  from_ts: from_ts,
  to_ts: to_ts,
  beginning_of_day: day.beginning_of_day.to_s,
}.inspect)

puts "cols=#{VehicleTracking.column_names.inspect}"
puts "vt_total=#{VehicleTracking.count rescue $!.message}"

vid = Order.kept.where(date: day).where.not(schedule_id: nil).limit(20)
  .map { |o| o.schedule&.vehicle_id }.compact.uniq.first
puts "sample_vid=#{vid}"

if vid
  latest = VehicleTracking.where(vehicle_id: vid).order(time: :desc).limit(1).first
  if latest
    coords = begin
      latest.lonlat&.coordinates
    rescue StandardError => e
      "err:#{e.class}:#{e.message}"
    end
    puts({
      latest_id: latest.id,
      time: latest.time,
      time_class: latest.time.class.name,
      speed: latest.speed,
      coords: coords,
      attrs_lonlat: latest.attributes["lonlat"],
    }.inspect)
  else
    puts "no tracks for vehicle at all"
  end

  cnt_ar = VehicleTracking.where(vehicle_id: vid, time: from_ts...to_ts).count
  puts "ar_range_count=#{cnt_ar}"

  sql = "SELECT COUNT(*) FROM vehicle_trackings WHERE vehicle_id=#{vid.to_i} AND time >= #{from_ts} AND time < #{to_ts}"
  puts "sql_unix_count=#{ActiveRecord::Base.connection.select_value(sql)}"

  # maybe time stored as ms
  sql_ms = "SELECT COUNT(*) FROM vehicle_trackings WHERE vehicle_id=#{vid.to_i} AND time >= #{from_ts * 1000} AND time < #{to_ts * 1000}"
  puts "sql_ms_count=#{ActiveRecord::Base.connection.select_value(sql_ms)}"

  # any points that day across all vehicles
  sql_all = "SELECT COUNT(*) FROM vehicle_trackings WHERE time >= #{from_ts} AND time < #{to_ts}"
  puts "sql_all_unix=#{ActiveRecord::Base.connection.select_value(sql_all)}"

  # sample times near day
  rows = ActiveRecord::Base.connection.exec_query(
    "SELECT id, vehicle_id, time, speed FROM vehicle_trackings WHERE vehicle_id=#{vid.to_i} ORDER BY time DESC LIMIT 5"
  ).rows
  puts "recent_rows=#{rows.inspect}"

  # try ST_AsText
  begin
    geo = ActiveRecord::Base.connection.exec_query(
      "SELECT time, speed, ST_AsText(lonlat::geometry) FROM vehicle_trackings WHERE vehicle_id=#{vid.to_i} AND time >= #{from_ts} AND time < #{to_ts} LIMIT 3"
    ).rows
    puts "geo_rows=#{geo.inspect}"
  rescue StandardError => e
    puts "geo_err=#{e.class}:#{e.message}"
  end
end
