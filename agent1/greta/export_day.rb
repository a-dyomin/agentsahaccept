#!/usr/bin/env ruby
# frozen_string_literal: true
# Export one day from Greta for Agent1 shadow ingest (compact).
# Usage: RAILS_ENV=production bundle exec rails runner export_day.rb YYYY-MM-DD

require "json"

R = 6_371_000.0
PHOTO_RADIUS_M = 100.0
# ГЕО: хотя бы один снимок ≤ PHOTO_RADIUS_M от площадки (geo_min)
TRACK_RADIUS_M = 200.0
NO_PICKUP_TRACK_RADIUS_M = 300.0
FOTO_DOEZD_RADIUS_M = 100.0
TIME_TOL_MIN = 7
NO_PICKUP_TIME_TOL_MIN = 5
TRACK_WINDOW_MIN = 30

# Greta Site.stype enum → UI/CSV label (ровно два значения)
STYPE_LABEL = {
  "containers" => "Контейнерная площадка",
  "scheduled" => "Сигнальный метод"
}.freeze

def site_stype_label(site)
  return nil unless site
  raw = site.stype
  return nil if raw.nil?
  STYPE_LABEL[raw.to_s] || raw.to_s
end

def haversine_m(lat1, lon1, lat2, lon2)
  p1 = lat1 * Math::PI / 180
  p2 = lat2 * Math::PI / 180
  dphi = (lat2 - lat1) * Math::PI / 180
  dlmb = (lon2 - lon1) * Math::PI / 180
  a = Math.sin(dphi / 2)**2 + Math.cos(p1) * Math.cos(p2) * Math.sin(dlmb / 2)**2
  2 * R * Math.asin(Math.sqrt(a))
end

day = Date.parse(ARGV[0] || (Date.today - 1).to_s)
limit = ARGV[1].to_i
limit = nil if limit <= 0

base_orders = Order.kept.where(date: day)
if limit
  order_ids = base_orders.order(:id).limit(limit).pluck(:id)
  orders = base_orders.where(id: order_ids)
else
  orders = base_orders
  order_ids = orders.pluck(:id)
end
from_ts = day.beginning_of_day.to_i
to_ts = (day + 1).beginning_of_day.to_i
schedule_ids = orders.where.not(schedule_id: nil).reorder(nil).distinct.pluck(:schedule_id)
schedules = Schedule.where(id: schedule_ids).index_by(&:id)
vehicle_ids = schedules.values.map(&:vehicle_id).compact.uniq
vehicles = Vehicle.kept.where(id: vehicle_ids).index_by(&:id)

site_ids = orders.distinct.pluck(:site_id).compact
sites = Site.kept.where(id: site_ids).index_by(&:id)

photos = Photo.kept.where(order_id: order_ids)
photo_ids = photos.pluck(:id)
atts = ActiveStorage::Attachment.where(record_type: "Photo", record_id: photo_ids)
blobs = ActiveStorage::Blob.where(id: atts.map(&:blob_id)).index_by(&:id)
att_by_photo = atts.index_by(&:record_id)
exifs = PhotoExif.kept.where(photo_id: photo_ids).index_by(&:photo_id)

photos_by_order = photos.group_by(&:order_id)
reports_rel = ReportSite.kept.where(order_id: order_ids)
reports_count = reports_rel.count
reports = reports_rel.index_by(&:order_id)
fail_reasons = FailReason.all.index_by(&:id) rescue {}

# Tracks via Wialon API — NEVER query vehicle_trackings (table too large for Postgres).
# Same path Greta monitoring uses: Wialon::Service#tracks_by_interval
tracks_by_vehicle = Hash.new { |h, k| h[k] = [] }
wialon_vehicles = 0
wialon_ok_batches = 0
wialon_fail_batches = 0
begin
  vid_to_wid = {}
  vehicles.each_value do |v|
    wid = v.wialon_id
    next if wid.nil? || wid.to_s.strip.empty?
    vid_to_wid[v.id] = wid.to_i
  end
  wialon_vehicles = vid_to_wid.size
  wid_to_vid = vid_to_wid.invert
  wialon = Wialon::Service.new
  vid_to_wid.each_slice(8) do |batch|
    items = batch.map do |_vid, wid|
      { id: wid, time_from: from_ts, time_to: to_ts, schedule_id: nil }
    end
    ok, results = wialon.tracks_by_interval(items)
    unless ok && results
      wialon_fail_batches += 1
      warn "wialon tracks_by_interval failed batch_wids=#{batch.map(&:last).inspect}"
      next
    end
    wialon_ok_batches += 1
    results.each do |(_sched, wid), pts|
      vid = wid_to_vid[wid.to_i]
      next unless vid
      Array(pts).each do |p|
        lat = p[:lat] || p["lat"]
        lon = p[:lon] || p["lon"]
        next if lat.nil? || lon.nil?
        at = p[:at] || p["at"]
        t_sec = at.respond_to?(:to_i) ? at.to_i : at.to_i
        tracks_by_vehicle[vid] << {
          t: t_sec,
          lon: lon.to_f,
          lat: lat.to_f,
          speed: p[:speed] || p["speed"]
        }
      end
    end
  end
  warn "wialon tracks vehicles=#{wialon_vehicles} ok_batches=#{wialon_ok_batches} fail_batches=#{wialon_fail_batches} points=#{tracks_by_vehicle.values.sum(&:size)}"
rescue StandardError => e
  warn "wialon track preload failed: #{e.class}: #{e.message}"
end

providers = Provider.where(id: orders.distinct.pluck(:provider_id).compact).index_by(&:id) rescue {}
waste_types = WasteType.where(id: orders.distinct.pluck(:waste_type_id).compact).index_by(&:id) rescue {}

orders_out = []
photos_out = []

orders.find_each(batch_size: 500) do |o|
  site = sites[o.site_id]
  site_lon = site_lat = nil
  if site
    begin
      c = site.lonlat&.coordinates
      site_lon, site_lat = c[0], c[1] if c
    rescue StandardError
    end
  end

  sch = o.schedule_id && schedules[o.schedule_id]
  veh_id = sch&.vehicle_id
  plate = veh_id && vehicles[veh_id]&.license_plate

  phs = photos_by_order[o.id] || []
  geo_min = nil
  geo_out = 0
  geo_no = 0
  photo_times = []
  phs.each do |ph|
    att = att_by_photo[ph.id]
    blob = att && blobs[att.blob_id]
    ex = exifs[ph.id]
    lon = lat = nil
    begin
      c = ex&.lonlat&.coordinates
      lon, lat = c[0], c[1] if c
    rescue StandardError
    end
    if lon.nil? || lat.nil?
      geo_no += 1
    elsif site_lat && site_lon
      d = haversine_m(site_lat, site_lon, lat, lon)
      geo_min = d if geo_min.nil? || d < geo_min
      geo_out += 1 if d > PHOTO_RADIUS_M
    end
    photo_times << ph.time.to_i if ph.time
    # Public Selectel URL — TZ: JPEG mirror not needed, fetch on demand without session
    photo_url = blob&.key && "https://s3.ru-1.storage.selcloud.ru/main/#{blob.key}"
    photos_out << {
      id: ph.id,
      order_id: o.id,
      schedule_id: ph.try(:schedule_id) || o.schedule_id,
      ptype: ph.ptype,
      time: ph.time&.iso8601,
      filename: ph.filename,
      blob_key: blob&.key,
      photo_url: photo_url,
      lon: lon,
      lat: lat
    }
  end

  geo_flag = if geo_min.nil?
               (geo_no.positive? || phs.empty?) ? "ND" : "ND"
             else
               geo_min <= PHOTO_RADIUS_M ? 1 : 0
             end

  track_exists = false
  track_min = nil
  arrival_ts = nil
  arrival_lat = nil
  arrival_lon = nil
  time_dev_min = nil
  time_flag = "ND"
  track_flag = "ND"
  foto_doezd_m = nil
  foto_doezd_flag = "ND"

  if veh_id && site_lat && site_lon
    pts = tracks_by_vehicle[veh_id]
    track_exists = pts.any?
    if track_exists
      # nearest point to site overall day, then refine by photo window
      best = nil
      pts.each do |p|
        d = haversine_m(site_lat, site_lon, p[:lat], p[:lon])
        best = [d, p] if best.nil? || d < best[0]
      end
      if best
        track_min = best[0]
        arrival_ts = best[1][:t]
        arrival_lat = best[1][:lat]
        arrival_lon = best[1][:lon]
      end
      # photo-anchored search if photos exist
      if photo_times.any?
        anchored = nil
        photo_times.each do |pt|
          window = pts.select { |p| (p[:t] - pt).abs <= TRACK_WINDOW_MIN * 60 }
          window.each do |p|
            d = haversine_m(site_lat, site_lon, p[:lat], p[:lon])
            anchored = [d, p, pt] if anchored.nil? || d < anchored[0]
          end
        end
        if anchored
          track_min = anchored[0]
          arrival_ts = anchored[1][:t]
          arrival_lat = anchored[1][:lat]
          arrival_lon = anchored[1][:lon]
          time_dev_min = ((anchored[2] - arrival_ts).abs / 60.0)
        end
      end
      radius = o.state == "canceled_by_driver" ? NO_PICKUP_TRACK_RADIUS_M : TRACK_RADIUS_M
      track_flag = track_min && track_min <= radius ? 1 : 0
      tol = o.state == "canceled_by_driver" ? NO_PICKUP_TIME_TOL_MIN : TIME_TOL_MIN
      time_flag = if time_dev_min.nil?
                    "ND"
                  else
                    time_dev_min <= tol ? 1 : 0
                  end
      # ФОТО_ДОЕЗД (невывоз §5.3): хотя бы один снимок ≤100м от точки доезда
      if arrival_lat && arrival_lon
        phs.each do |ph|
          ex = exifs[ph.id]
          lon = lat = nil
          begin
            c = ex&.lonlat&.coordinates
            lon, lat = c[0], c[1] if c
          rescue StandardError
          end
          next if lon.nil? || lat.nil?
          d = haversine_m(arrival_lat, arrival_lon, lat, lon)
          foto_doezd_m = d if foto_doezd_m.nil? || d < foto_doezd_m
        end
        foto_doezd_flag = if foto_doezd_m.nil?
                            "ND"
                          else
                            foto_doezd_m <= FOTO_DOEZD_RADIUS_M ? 1 : 0
                          end
      end
    else
      # нет точек трека: ТРЕК_ЕСТЬ=0; ТРЕК/ВРЕМЯ/ФОТО_ДОЕЗД = ND (ставит Stage1)
      track_flag = "ND"
      time_flag = "ND"
      foto_doezd_flag = "ND"
    end
  end

  report = reports[o.id]
  fr_name = report && fail_reasons[report.fail_reason_id]&.name

  orders_out << {
    id: o.id,
    date: o.date.to_s,
    state: o.state,
    site_id: o.site_id,
    site_address: site&.address,
    site_stype: site_stype_label(site),
    site_lat: site_lat,
    site_lon: site_lon,
    schedule_id: o.schedule_id,
    vehicle_id: veh_id,
    plate: plate,
    provider_id: o.provider_id,
    provider_name: providers[o.provider_id]&.name,
    waste_type_id: o.waste_type_id,
    waste_type_name: waste_types[o.waste_type_id]&.name,
    create_type: o.create_type,
    change_source: o.change_source,
    transfered: o.transfered,
    container_count: (o.container_ids.is_a?(Array) ? o.container_ids.size : nil),
    started_at: o.started_at&.iso8601,
    finished_at: o.finished_at&.iso8601,
    canceled_at: o.canceled_at&.iso8601,
    # human labels
    human_breach_state: o.breach_state,
    human_accept_note: o.breach_accept_note,
    human_regoper_note: o.breach_accept_regoper_note,
    # report
    has_report: !report.nil?,
    report_success: report&.success,
    report_comment: report&.comment,
    fail_reason: fr_name,
    # stage1 precomputed
    photo_count: phs.size,
    geo_flag: geo_flag,
    geo_min_m: geo_min&.round(1),
    geo_out: geo_out,
    geo_no_coord: geo_no,
    track_exists: track_exists,
    track_flag: track_flag,
    track_min_m: track_min&.round(1),
    arrival_ts: arrival_ts,
    arrival_lat: arrival_lat,
    arrival_lon: arrival_lon,
    time_flag: time_flag,
    time_dev_min: time_dev_min&.round(2),
    foto_doezd_flag: foto_doezd_flag,
    foto_doezd_m: foto_doezd_m&.round(1)
  }
end

sites_out = sites.values.map do |s|
  c = begin
    s.lonlat&.coordinates
  rescue StandardError
    nil
  end
  { id: s.id, address: s.address, name: s.name, stype: site_stype_label(s), lon: c && c[0], lat: c && c[1] }
end

# Greta «ID смены» = schedules.id (= orders.schedule_id / photos.schedule_id)
schedules_out = schedules.values.map do |s|
  v = s.vehicle_id && vehicles[s.vehicle_id]
  {
    id: s.id,
    vehicle_id: s.vehicle_id,
    plate: v&.license_plate,
    driver_id: s.try(:driver_id),
    state: s.try(:state),
    start_at: s.try(:start_at)&.iso8601,
    finish_at: s.try(:finish_at)&.iso8601,
    started_at: s.try(:started_at)&.iso8601,
    finished_at: s.try(:finished_at)&.iso8601,
    route_id: s.try(:route_id),
    scope_type: s.try(:scope_type),
    change_source: s.try(:change_source),
    mileage: s.try(:mileage),
    provider_id: s.try(:provider_id)
  }
end

out = {
  day: day.to_s,
  exported_at: Time.now.utc.iso8601,
  counts: {
    orders: orders_out.size,
    photos: photos_out.size,
    reports: reports_count,
    vehicles: vehicles.size,
    sites: sites_out.size,
    sites_with_coords: sites_out.count { |s| s[:lat] && s[:lon] },
    schedules: schedules_out.size,
    fail_reasons: fail_reasons.size,
    tracks_points: tracks_by_vehicle.values.sum(&:size),
    wialon_vehicles: wialon_vehicles,
    track_source: "wialon"
  },
  sites: sites_out,
  schedules: schedules_out,
  orders: orders_out,
  photos: photos_out
}

STDOUT.write(JSON.generate(out))
