#!/bin/bash
set -eu
/home/admin-akea/agent1/venv/bin/python <<'PY'
from pathlib import Path
p=Path('/home/admin-akea/agent1/app/stage1_shadow.py').read_text(encoding='utf-8')
print('has_GEO_BY_TRACK', 'ГЕО_ПО_ТРЕКУ' in p)
print('has_Wialon', 'Wialon' in p)
for i,l in enumerate(p.splitlines(),1):
    if 'ГЕО_ПО_ТРЕКУ' in l or 'Wialon' in l or 'geo_fail and track' in l or 'место не проверено' in l:
        print(f'{i}:{l}')
PY
set -a
# shellcheck disable=SC1091
source /home/admin-akea/agent1/.env
set +a
/home/admin-akea/agent1/venv/bin/python <<'PY'
import os,psycopg,json
from psycopg.rows import dict_row
url=next(os.environ[k] for k in ("DATABASE_URL","AGENT1_DATABASE_URL","AGENT1_DB_URL") if os.environ.get(k))
with psycopg.connect(url,row_factory=dict_row) as conn:
    cur=conn.cursor()
    cur.execute("SELECT day::text d, COUNT(*) FILTER (WHERE stage1 ? %s)::int k, COUNT(*) FILTER (WHERE stage1->>%s='1')::int v FROM agent_decisions GROUP BY day ORDER BY day", ('ГЕО_ПО_ТРЕКУ','ГЕО_ПО_ТРЕКУ'))
    print('geo_track_by_day', cur.fetchall())
    cur.execute("""SELECT COUNT(*)::int n FROM agent_decisions WHERE itog='К ЧЕЛОВЕКУ' AND COALESCE(pometki,'') ILIKE %s""", ('%место не проверено%',))
    print('human_mesto', cur.fetchone())
    cur.execute("""SELECT COUNT(*)::int n FROM agent_decisions WHERE stage1->>'ГЕО'='ND' AND itog='К ЧЕЛОВЕКУ'""")
    print('human_geo_nd', cur.fetchone())
    cur.execute("""SELECT COUNT(*)::int n FROM agent_decisions WHERE stage1->>'ГЕО'='0' AND itog LIKE 'НАРУШЕНИЕ%%'""")
    print('viol_geo0', cur.fetchone())
PY
