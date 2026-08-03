#!/bin/bash
set -euo pipefail
cd "$HOME/greta-backend/current"
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
eval "$(rbenv init -)"
RAILS_ENV=production bundle exec rails runner '
puts "DB=" + ActiveRecord::Base.connection_db_config.database.to_s
puts "photo_exifs=" + PhotoExif.count.to_s
puts "photos=" + Photo.count.to_s
puts "vehicle_trackings=" + VehicleTracking.count.to_s
puts "vehicles_with_wialon=" + Vehicle.where.not(wialon_id: [nil, ""]).count.to_s
d = Date.new(2026, 7, 12)
from = d.beginning_of_day.to_i
to = (d + 1).beginning_of_day.to_i
puts "trackings_on_2026-07-12=" + VehicleTracking.where(time: from...to).count.to_s
t = VehicleTracking.where(time: from...to).limit(1).first
if t
  puts "sample_tracking vehicle_id=#{t.vehicle_id} time=#{t.time} speed=#{t.speed} lonlat=#{t.lonlat}"
end
pex = PhotoExif.joins(:photo).where(photos: { time: d.beginning_of_day..d.end_of_day }).where.not(lonlat: nil).limit(1).exists?
puts "sample_photo_exif_with_coords_on_day=" + pex.to_s
'
