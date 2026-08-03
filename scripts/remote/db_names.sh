#!/bin/bash
awk '/^production:/,/^[a-z]/ {print}' "$HOME/greta-backend/shared/config/database.yml" | sed -E 's/(password:).*/\1 [REDACTED]/'
echo '---'
# try listing DBs gretaadmin can see
psql -h localhost -U greta_backend -d greta_backend_production -c "SELECT count(*) AS vehicle_trackings FROM vehicle_trackings;" 2>&1 | head -20
psql -h localhost -U greta_backend -d greta_backend -c "SELECT count(*) AS vehicle_trackings FROM vehicle_trackings;" 2>&1 | head -20
# peer as gretaadmin
psql -d greta_backend_production -c "SELECT 1" 2>&1 | head -10
