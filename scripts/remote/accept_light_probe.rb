# lightweight samples only — no full-table COUNT
d = Date.new(2026, 7, 12)
puts "DB=#{ActiveRecord::Base.connection_db_config.database}"
puts "tz=#{Time.zone.name}"

v = Vehicle.kept.where.not(wialon_id: [nil, ""]).limit(1).first
puts "vehicle id=#{v && v.id} plate=#{v && v.license_plate} wialon_id=#{v && v.wialon_id} imei=#{v && v.wialon_imei}"

from = d.beginning_of_day.to_i
to = (d + 1).beginning_of_day.to_i
if v
  t = VehicleTracking.where(vehicle_id: v.id, time: from..to).order(:time).limit(1).first
  coords = begin
    t && t.lonlat.respond_to?(:coordinates) ? t.lonlat.coordinates : (t && t.lonlat)
  rescue StandardError
    t && t.lonlat
  end
  puts "track_sample vehicle=#{v.id} present=#{!t.nil?} time=#{t && t.time} speed=#{t && t.speed} lonlat=#{coords.inspect}"
  puts "track_count_vehicle_day=#{VehicleTracking.where(vehicle_id: v.id, time: from..to).count}"
end

o = Order.kept.where(date: d).where.not(schedule_id: nil).limit(1).first
puts "order id=#{o && o.id} date=#{o && o.date} state=#{o && o.state} site_id=#{o && o.site_id} schedule_id=#{o && o.schedule_id}"
if o
  s = Site.kept.find_by(id: o.site_id)
  sc = begin
    s && s.lonlat.respond_to?(:coordinates) ? s.lonlat.coordinates : (s && s.lonlat)
  rescue StandardError
    s && s.lonlat
  end
  type_keys = s ? s.attributes.keys.grep(/type/) : []
  puts "site id=#{s && s.id} type_keys=#{type_keys.inspect} lonlat=#{sc.inspect} address=#{s && s.try(:address)}"
  puts "photos_for_order=#{Photo.kept.where(order_id: o.id).count}"
  Photo.kept.where(order_id: o.id).limit(3).each do |ph|
    att = ActiveStorage::Attachment.find_by(record_type: "Photo", record_id: ph.id)
    blob = att && att.blob
    ex = PhotoExif.kept.find_by(photo_id: ph.id)
    ec = begin
      ex && ex.lonlat.respond_to?(:coordinates) ? ex.lonlat.coordinates : (ex && ex.lonlat)
    rescue StandardError
      ex && ex.lonlat
    end
    puts "photo id=#{ph.id} ptype=#{ph.ptype} time=#{ph.time} file=#{ph.filename} blob_key=#{blob && blob.key} service=#{blob && blob.service_name} exif=#{ec.inspect}"
  end
  sch = Schedule.find_by(id: o.schedule_id)
  veh = Vehicle.find_by(id: sch && sch.try(:vehicle_id))
  puts "schedule id=#{sch && sch.id} vehicle_id=#{sch && sch.try(:vehicle_id)} plate=#{veh && veh.license_plate}"
end
