#!/bin/bash
set -eu
set -a
# shellcheck disable=SC1091
source /home/admin-akea/agent1/.env
set +a
cd /home/admin-akea/agent1/app
../venv/bin/python <<'PY'
import os
import psycopg
from psycopg.rows import dict_row

url = None
for k in ("DATABASE_URL", "AGENT1_DATABASE_URL", "AGENT1_DB_URL"):
    if os.environ.get(k):
        url = os.environ[k]
        break
day = "2026-08-03"
conn = psycopg.connect(url, row_factory=dict_row)
cur = conn.cursor()

print("=== ptype по всем фото дня ===")
cur.execute("SELECT ptype, COUNT(*)::int n FROM photos_day WHERE day=%s::date GROUP BY ptype ORDER BY n DESC", (day,))
for r in cur.fetchall():
    print(" ", r["ptype"], r["n"])

print("\n=== сколько фото на заявку (чек-лист 1а) ===")
cur.execute("""
 SELECT k, COUNT(*)::int orders FROM (
   SELECT p.order_id, COUNT(*)::int k
   FROM photos_day p
   JOIN agent_decisions d ON d.day=p.day AND d.order_id=p.order_id AND d.checklist='1а'
   WHERE p.day=%s::date GROUP BY p.order_id
 ) t GROUP BY k ORDER BY k
""", (day,))
for r in cur.fetchall():
    print(f"  {r['k']} фото -> {r['orders']} заявок")

print("\n=== кадры образцовых заявок (те, где А3=0) ===")
for oid in (19298843, 19297813, 19297548, 19281356, 19298295):
    cur.execute("""
      SELECT photo_id, ptype, filename, time::text t, blob_key IS NOT NULL bk, photo_url IS NOT NULL pu
      FROM photos_day WHERE day=%s::date AND order_id=%s ORDER BY filename
    """, (day, oid))
    rows = cur.fetchall()
    print(f"\n  заявка {oid}: {len(rows)} фото")
    for r in rows:
        print(f"    {r['photo_id']} ptype={r['ptype']} {r['filename']} time={r['t']} key={r['bk']} url={r['pu']}")

print("\n=== сколько заявок 1а имеют кадры разных ptype ===")
cur.execute("""
 SELECT COUNT(*)::int n FROM (
   SELECT p.order_id FROM photos_day p
   JOIN agent_decisions d ON d.day=p.day AND d.order_id=p.order_id AND d.checklist='1а'
   WHERE p.day=%s::date GROUP BY p.order_id HAVING COUNT(DISTINCT p.ptype) > 1
 ) t
""", (day,))
print(" ", cur.fetchone())

print("\n=== разброс времени между первым и последним кадром (1а) ===")
cur.execute("""
 WITH t AS (
   SELECT p.order_id,
     MIN(substring(p.filename from '[0-9]{8}_([0-9]{6})')) mn,
     MAX(substring(p.filename from '[0-9]{8}_([0-9]{6})')) mx,
     COUNT(*)::int k
   FROM photos_day p
   JOIN agent_decisions d ON d.day=p.day AND d.order_id=p.order_id AND d.checklist='1а'
   WHERE p.day=%s::date AND p.filename ~ '[0-9]{8}_[0-9]{6}'
   GROUP BY p.order_id HAVING COUNT(*)>1
 )
 SELECT COUNT(*)::int orders,
   COUNT(*) FILTER (WHERE mn=mx)::int same_time,
   ROUND(AVG(
     (substring(mx,1,2)::int*3600+substring(mx,3,2)::int*60+substring(mx,5,2)::int) -
     (substring(mn,1,2)::int*3600+substring(mn,3,2)::int*60+substring(mn,5,2)::int)
   )) avg_sec
 FROM t
""", (day,))
print(" ", cur.fetchone())

print("\n=== photos_cached vs photos_total (1а, vision ok) ===")
cur.execute("""
 SELECT (stage2->>'photos_total') tot, (stage2->>'photos_cached') cch, COUNT(*)::int n
 FROM agent_decisions WHERE day=%s::date AND checklist='1а' AND stage2->>'status'='ok'
 GROUP BY 1,2 ORDER BY n DESC LIMIT 10
""", (day,))
for r in cur.fetchall():
    print(f"  total={r['tot']} cached={r['cch']} -> {r['n']}")
conn.close()
PY
