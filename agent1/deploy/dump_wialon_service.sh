#!/bin/bash
set +e
ssh -i ~/.ssh/greta_ro -p 34023 -o IdentitiesOnly=yes -o BatchMode=yes gretaadmin@greta.akea-ds.ru \
  'sed -n "1,220p" ~/greta-backend/current/app/services/wialon/service.rb; echo "===="; sed -n "1,120p" ~/greta-backend/current/app/services/vehicle_trackings/check_report_site.rb; echo "===="; ls ~/greta-backend/current/app/services/wialon/; echo "===="; sed -n "960,1020p" ~/greta-backend/current/app/services/monitor_dashboard/api.rb'
