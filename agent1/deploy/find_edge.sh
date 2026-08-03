#!/bin/bash
set +e
echo "=== LAN http servers ==="
for ip in 192.168.111.5 192.168.111.50 192.168.111.59; do
  echo "-- $ip Host demosah"
  curl -sSI --connect-timeout 2 --max-time 4 -H "Host: demosah.izhon.ru" "http://$ip/" 2>&1 | head -12
  echo "-- $ip Host agent1"
  curl -sSI --connect-timeout 2 --max-time 4 -H "Host: agent1.izhon.ru" "http://$ip/" 2>&1 | head -12
  echo "-- $ip :443"
  curl -skSI --connect-timeout 2 --max-time 4 -H "Host: demosah.izhon.ru" "https://$ip/" 2>&1 | head -12
done
echo "=== ssh .50 ==="
ssh -o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=no admin-akea@192.168.111.50 "hostname; id; ls /etc/nginx/sites-enabled 2>/dev/null; which openresty; ls /usr/local/openresty/nginx/conf/conf.d 2>/dev/null; ls /etc/openresty 2>/dev/null" 2>&1 | head -40
echo "=== docker/proxy hints on izhon ==="
ls /opt 2>/dev/null
find /opt /home/admin-akea -maxdepth 3 -iname '*proxy*' -o -iname '*openresty*' -o -iname '*traefik*' 2>/dev/null | head -30
cat /home/admin-akea/agent1/.env 2>/dev/null | grep -E '^[A-Z_]+=' | cut -d= -f1
