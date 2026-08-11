#!/bin/bash
set -eu
set -a
# shellcheck disable=SC1091
source /home/admin-akea/agent1/.env
set +a
APP=/home/admin-akea/agent1/app
PY=/home/admin-akea/agent1/venv/bin/python

echo "=== runtime ==="
systemctl is-active agent1-api agent1-worker
grep -E 'AGENT1_VISION|AGENT1_STAGE2|AGENT1_WRITE' /home/admin-akea/agent1/.env || true

echo
echo "=== status ==="
curl --noproxy '*' -sS -m 30 'http://127.0.0.1:8101/api/status' -o /tmp/st_now.json
"$PY" <<'PY'
import json
d=json.load(open("/tmp/st_now.json"))
c=d.get("counts",{})
print("state:", d.get("agent_state"))
print("mode:", d.get("mode"))
print("days:", d.get("available_days"))
print("productivity:", d.get("labor_productivity_pct"))
print("active_run:", d.get("active_run"))
for k in ("processed","queued","in_progress","auto_checked","sent_to_human","not_in_work","failed_shift","photo_by_content","photo_by_geo_only"):
    print(f"  {k}:", c.get(k))
print("itog:")
for x in d.get("itog_distribution") or []:
    print(f"  {x['itog']}: {x['n']}")
PY

echo
echo "=== decisions by day ==="
"$PY" <<'PY'
import os,psycopg
from psycopg.rows import dict_row
url=next(os.environ[k] for k in ("DATABASE_URL","AGENT1_DATABASE_URL","AGENT1_DB_URL") if os.environ.get(k))
with psycopg.connect(url,row_factory=dict_row) as conn:
    cur=conn.cursor()
    cur.execute("""
      SELECT day::text,
             COUNT(*)::int n,
             COUNT(*) FILTER (WHERE itog='К ЧЕЛОВЕКУ')::int human,
             COUNT(*) FILTER (WHERE itog='ЧИСТО' OR itog LIKE 'НАРУШЕНИЕ%%')::int auto,
             COUNT(*) FILTER (WHERE stage1->>'ГЕО_ПО_ТРЕКУ'='1')::int geo_track
      FROM agent_decisions GROUP BY day ORDER BY day
    """)
    for r in cur.fetchall():
        scope=r['auto']+r['human']
        prod=round(100*r['auto']/scope,1) if scope else None
        print(r['day'], 'n=',r['n'],'prod=',prod,'geo_by_track=',r['geo_track'])
PY

echo
echo "=== agent deviations vs classic TZ (code fingerprints) ==="
cd "$APP"
"$PY" <<'PY'
import stage1_shadow, stage2, checklist_prompts, checklist_verdict, inspect, merge_itog
src = inspect.getsource(stage1_shadow.decide_stage1)
print("VISION_MODEL default/live:", stage2.VISION_MODEL)
print("VISION_DETAIL:", stage2.VISION_DETAIL)
print("POSITIVE_CODES:", checklist_verdict.POSITIVE_CODES)
print("has soften_o3:", hasattr(checklist_verdict,'soften_o3'))
print("has frame_label:", hasattr(stage2,'frame_label'))
print("PTYPE:", getattr(stage2,'PTYPE_LABELS',None))
print("PTYPE no removal:", getattr(stage2,'PTYPE_LABELS_NO_REMOVAL',None))
print("GEO_BY_TRACK rule in stage1:", 'ГЕО_ПО_ТРЕКУ' in src or 'ГЕО_ПО_ТРЕКУ' in inspect.getsource(stage1_shadow))
print("mode hardcoded shadow: check main")
print("A3 prompt snippet:")
q=checklist_prompts.questions_for('1а')
for line in q.splitlines():
    if line.startswith(('О3','А2','А3','А4')):
        print(' ', line)
print("checklist 2 O3/N5:")
for line in checklist_prompts.questions_for('2').splitlines():
    if line.startswith(('О3','Н5','Н6')):
        print(' ', line)
print("PHOTO_RADIUS still in greta export (local copy may differ)")
PY
grep -n "PHOTO_RADIUS\|TRACK_RADIUS\|GEO_ПО_ТРЕКУ\|soften_o3\|POSITIVE_CODES\|mode.*shadow\|WRITEBACK" \
  /home/admin-akea/agent1/app/*.py /home/admin-akea/agent1/greta/*.rb 2>/dev/null | head -80
