#!/bin/bash
set +e
ssh -i ~/.ssh/greta_ro -p 34023 -o IdentitiesOnly=yes -o BatchMode=yes gretaadmin@greta.akea-ds.ru \
  'ps -eo pid,etime,cmd | grep -E "rails|ruby|bundle" | grep -v grep | head -20; echo ---; wc -l ~/agent1_export/vt_light.rb; head -50 ~/agent1_export/vt_light.rb'
echo CHECK_DONE
