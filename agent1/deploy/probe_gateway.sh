#!/bin/bash
# Probe / try manage edge gateway 192.168.111.5
set +e
GW=192.168.111.5
echo "=== gateway $GW ==="
ip route | head -5
echo "=== ports ==="
for p in 22 80 443 8443 9443 8080 8888 10000 2082 2083 2086 2087 2096 2222 3000 9090; do
  if timeout 1 bash -c "echo >/dev/tcp/$GW/$p" 2>/dev/null; then echo OPEN $p; else echo closed $p; fi
done
echo "=== https headers ==="
curl -skSI --connect-timeout 3 --max-time 5 -H "Host: demosah.izhon.ru" "https://$GW/" 2>&1 | head -20
curl -skSI --connect-timeout 3 --max-time 5 -H "Host: agent1.izhon.ru" "https://$GW/" 2>&1 | head -20
curl -skSI --connect-timeout 3 --max-time 5 "https://$GW/" 2>&1 | head -20
echo "=== try ssh variants ==="
for user in root admin admin-akea akea ubuntu; do
  ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no -i ~/.ssh/greta_ro "$user@$GW" "hostname" 2>&1 | head -2
done
echo EDGE_PROBE_DONE
