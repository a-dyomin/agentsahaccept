#!/bin/bash
set +e
ssh -i ~/.ssh/greta_ro -p 34023 -o IdentitiesOnly=yes -o BatchMode=yes gretaadmin@greta.akea-ds.ru bash -s <<'REMOTE'
set +e
cd ~/greta-backend/current || exit 1
echo "=== wialon ruby hits ==="
grep -RIn --include='*.rb' -i wialon app lib config 2>/dev/null | grep -v vendor | head -80
echo "=== env/credentials hints ==="
grep -RIn -i wialon config .env* 2>/dev/null | head -40
echo "=== vehicles columns ==="
export PATH=$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH
eval "$(rbenv init -)"
RAILS_ENV=production bundle exec rails runner 'puts Vehicle.column_names.grep(/wialon|imei|glonass/i).inspect; v=Vehicle.kept.where.not(wialon_id:[nil,\"\"]).limit(1).first; puts({id:v&.id,plate:v&.license_plate,wialon_id:v&.wialon_id,imei:v&.wialon_imei}.inspect)' 2>&1 | tail -30
echo GRETA_WIALON_SCAN_DONE
REMOTE
