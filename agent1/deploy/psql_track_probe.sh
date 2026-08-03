#!/bin/bash
set -euo pipefail
sed -i 's/\r$//' ~/agent1/greta/track_probe.sql
scp -i ~/.ssh/greta_ro -P 34023 -o IdentitiesOnly=yes -o BatchMode=yes \
  ~/agent1/greta/track_probe.sql gretaadmin@greta.akea-ds.ru:~/agent1_export/track_probe.sql

ssh -i ~/.ssh/greta_ro -p 34023 -o IdentitiesOnly=yes -o BatchMode=yes gretaadmin@greta.akea-ds.ru bash -s <<'REMOTE'
set -euo pipefail
PASS=$(python3 -c '
import re
from pathlib import Path
t=Path("/home/gretaadmin/greta-backend/shared/config/database.yml").read_text()
for line in t.splitlines():
    s=line.strip()
    if s.startswith("#"):
        continue
    if s.startswith("password:"):
        print(s.split(":",1)[1].strip().strip("\"'\''"))
        break
')
export PGPASSWORD="$PASS"
psql -h localhost -U greta_backend -d greta_backend_production -f ~/agent1_export/track_probe.sql
REMOTE
echo PSQL_DONE
