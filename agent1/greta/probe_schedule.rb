# frozen_string_literal: true
# Probe Schedule / shift fields for Agent1. Usage: rails runner probe_schedule.rb [YYYY-MM-DD]
day = Date.parse(ARGV[0] || (Date.today - 2).to_s)
puts "day=#{day} tz=#{Time.zone.name}"

cols = ActiveRecord::Base.connection.columns("schedules").map(&:name)
puts "schedules_cols=#{cols.inspect}"

o = Order.kept.where(date: day).where.not(schedule_id: nil).limit(1).first
puts "sample_order id=#{o&.id} schedule_id=#{o&.schedule_id}"
if o
  sch = Schedule.find_by(id: o.schedule_id)
  puts "schedule_attrs=#{sch&.attributes&.inspect}"
  puts "schedule_methods_vehicle=#{sch.respond_to?(:vehicle_id)} vehicle=#{sch.try(:vehicle_id)}"
end

# photo link to schedule?
photo_cols = ActiveRecord::Base.connection.columns("photos").map(&:name) rescue []
puts "photos_cols_schedule=#{photo_cols.grep(/sched|shift|рейс|смен/i).inspect} all_has_schedule=#{photo_cols.include?('schedule_id')}"

# counts for day
n_orders = Order.kept.where(date: day).count
n_with = Order.kept.where(date: day).where.not(schedule_id: nil).count
n_sched = Order.kept.where(date: day).where.not(schedule_id: nil).distinct.count(:schedule_id)
puts "orders=#{n_orders} with_schedule_id=#{n_with} distinct_schedules=#{n_sched}"

# sample distinct schedules
ids = Order.kept.where(date: day).where.not(schedule_id: nil).limit(200).pluck(:schedule_id).uniq.first(5)
Schedule.where(id: ids).each do |s|
  v = Vehicle.find_by(id: s.try(:vehicle_id))
  puts({
    schedule_id: s.id,
    date: s.try(:date) || s.try(:planned_date) || s.try(:work_date),
    vehicle_id: s.try(:vehicle_id),
    plate: v&.license_plate,
    driver_id: s.try(:driver_id) || s.try(:user_id),
    status: s.try(:state) || s.try(:status),
    number: s.try(:number) || s.try(:num) || s.try(:name),
  }.inspect)
end
