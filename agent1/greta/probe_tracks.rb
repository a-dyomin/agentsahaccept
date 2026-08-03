d = Date.new(2026, 7, 12)
from = d.beginning_of_day.to_i
to = (d + 1).beginning_of_day.to_i
vids = Order.kept.where(date: d)
  .joins("INNER JOIN schedules ON schedules.id = orders.schedule_id")
  .distinct.pluck("schedules.vehicle_id").compact
puts "vehicles=#{vids.size}"
puts "tz=#{Time.zone.name} from=#{from} to=#{to}"
puts "any_tracks=#{VehicleTracking.where(time: from...to).limit(1).exists?}"
if vids.any?
  puts "tracks_sample_vehicles=#{VehicleTracking.where(vehicle_id: vids.first(30), time: from...to).count}"
  t = VehicleTracking.where(vehicle_id: vids.first, time: from...to).order(:time).first
  if t
    coords = begin
      t.lonlat.coordinates
    rescue StandardError
      t.lonlat
    end
    puts "sample vehicle=#{vids.first} time=#{t.time} speed=#{t.speed} lonlat=#{coords.inspect}"
  else
    # try without vehicle filter
    t2 = VehicleTracking.where(time: from...to).order(:time).first
    puts "any_day_sample=#{t2 && [t2.vehicle_id, t2.time, t2.speed]}"
    # maybe time is datetime not unix?
    puts "columns_hint=#{VehicleTracking.column_names.inspect}"
  end
end
