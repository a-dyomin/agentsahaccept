#!/bin/bash
set -euo pipefail
DAY="${1:-2026-07-12}"
KEY="${GRETA_SSH_KEY:-$HOME/.ssh/greta_ro}"
HOST="${GRETA_SSH_HOST:-greta.akea-ds.ru}"
PORT="${GRETA_SSH_PORT:-34023}"
USER="${GRETA_SSH_USER:-gretaadmin}"
BACKEND="${GRETA_BACKEND:-/home/gretaadmin/greta-backend/current}"

ssh -i "$KEY" -p "$PORT" -o StrictHostKeyChecking=no -o BatchMode=yes "${USER}@${HOST}" bash -s "$DAY" "$BACKEND" <<'REMOTE'
set -euo pipefail
DAY="$1"
BACKEND="$2"
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
cd "$BACKEND"
export RAILS_ENV=production
FROM_TS=$(bundle exec rails runner "d=Date.parse('$DAY'); puts d.beginning_of_day.to_i" 2>/dev/null | tail -1)
TO_TS=$(bundle exec rails runner "d=Date.parse('$DAY'); puts (d+1).beginning_of_day.to_i" 2>/dev/null | tail -1)
echo "=== vehicle_trackings probe day=$DAY window=[$FROM_TS,$TO_TS) ==="
bundle exec rails runner "
day = Date.parse('$DAY')
from_ts = day.beginning_of_day.to_i
to_ts = (day + 1).beginning_of_day.to_i
c = ActiveRecord::Base.connection
puts 'COUNT total=' + c.select_value('SELECT COUNT(*) FROM vehicle_trackings').to_s
c.exec_query(\"SELECT column_name, data_type FROM information_schema.columns WHERE table_schema='public' AND table_name='vehicle_trackings' ORDER BY ordinal_position\").each { |r| puts r['column_name'] + ' | ' + r['data_type'].to_s }
puts 'COUNT day=' + c.select_value(\"SELECT COUNT(*) FROM vehicle_trackings WHERE time >= #{from_ts} AND time < #{to_ts}\").to_s
c.exec_query(\"SELECT vehicle_id, time, ST_AsText(lonlat) AS wkt FROM vehicle_trackings WHERE lonlat IS NOT NULL ORDER BY time DESC LIMIT 5\").each { |r| puts r.to_json }
"
REMOTE
