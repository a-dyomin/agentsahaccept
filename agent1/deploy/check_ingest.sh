#!/bin/bash
set +e
curl -sS http://127.0.0.1:8101/api/status | python3 -c 'import sys,json;d=json.load(sys.stdin);print("state",d.get("agent_state"));print("ingest",d.get("last_ingest"));print("events",d.get("recent_events")[:6])'
echo "==== greta procs ===="
ssh -i ~/.ssh/greta_ro -p 34023 -o IdentitiesOnly=yes -o BatchMode=yes gretaadmin@greta.akea-ds.ru \
  'pgrep -af export_day; pgrep -af "rails runner"; pgrep -af wialon_smoke'
echo CHECK_DONE
