vid = Order.kept.where(date: Date.new(2026, 7, 12)).where.not(schedule_id: nil).limit(1)
  .joins("INNER JOIN schedules ON schedules.id = orders.schedule_id")
  .pick("schedules.vehicle_id")
puts "vid=#{vid}"
t = VehicleTracking.where(vehicle_id: vid).order(time: :desc).limit(1).first
puts "latest=#{t && [t.time, t.speed, t.attributes['lonlat']]}"
puts "cols=#{VehicleTracking.column_names}"
# count for one vehicle around day via SQL
from = Date.new(2026, 7, 12).beginning_of_day.to_i
to = (Date.new(2026, 7, 12) + 1).beginning_of_day.to_i
sql = "SELECT COUNT(*) FROM vehicle_trackings WHERE vehicle_id=#{vid.to_i} AND time >= #{from} AND time < #{to}"
puts "sql_count=#{ActiveRecord::Base.connection.select_value(sql)}"
sql2 = "SELECT time, speed, ST_AsText(lonlat::geometry) FROM vehicle_trackings WHERE vehicle_id=#{vid.to_i} AND time >= #{from} AND time < #{to} LIMIT 3"
puts ActiveRecord::Base.connection.exec_query(sql2).rows.inspect
