#!/bin/bash
set +e
echo "=== izhon ssh children ==="
ps -eo pid,etime,cmd | grep -E 'greta|rails|probe|vt_light' | grep -v grep | head -30
echo "=== greta procs ==="
ssh -i ~/.ssh/greta_ro -p 34023 -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=15 \
  gretaadmin@greta.akea-ds.ru 'ps -eo pid,etime,pcpu,pmem,cmd | grep -E "rails|ruby|bundle|postgres" | grep -v grep | head -40; echo ---; ls -la ~/greta-backend/current/config/database.yml; echo ---; (test -f ~/greta-backend/shared/config/database.yml && head -40 ~/greta-backend/shared/config/database.yml) || true; (test -f ~/greta-backend/current/config/database.yml && head -40 ~/greta-backend/current/config/database.yml) || true'
echo CHECK2_DONE
