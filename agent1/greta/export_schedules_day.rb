# frozen_string_literal: true
# Light export: schedules (+ photo.schedule_id) for a day — no Wialon/tracks.
# Usage: RAILS_ENV=production bundle exec rails runner export_schedules_day.rb YYYY-MM-DD
require "json"

day = Date.parse(ARGV[0] || (Date.today - 2).to_s)
orders = Order.kept.where(date: day)
order_ids = orders.pluck(:id)
schedule_ids = orders.where.not(schedule_id: nil).reorder(nil).distinct.pluck(:schedule_id)
schedules = Schedule.where(id: schedule_ids).index_by(&:id)
vehicle_ids = schedules.values.map(&:vehicle_id).compact.uniq
vehicles = Vehicle.kept.where(id: vehicle_ids).index_by(&:id)

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

# photo → schedule_id mapping for enrichment
photos_out = Photo.kept.where(order_id: order_ids).map do |ph|
  {
    id: ph.id,
    order_id: ph.order_id,
    schedule_id: ph.try(:schedule_id)
  }
end

orders_out = orders.where.not(schedule_id: nil).pluck(:id, :schedule_id).map do |oid, sid|
  { id: oid, schedule_id: sid }
end

out = {
  day: day.to_s,
  exported_at: Time.now.utc.iso8601,
  kind: "schedules_enrich",
  counts: {
    orders_with_schedule: orders_out.size,
    schedules: schedules_out.size,
    photos: photos_out.size
  },
  schedules: schedules_out,
  orders: orders_out,
  photos: photos_out
}
STDOUT.write(JSON.generate(out))
