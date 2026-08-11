#!/bin/bash
set -eu
set -a
# shellcheck disable=SC1091
source /home/admin-akea/agent1/.env
set +a
cd /home/admin-akea/agent1/app
../venv/bin/python <<'PY'
"""Базовая частота О3=подделка в 1а при разной строке про «неприменимость»."""
import os
import psycopg
from psycopg.rows import dict_row

import stage2
from photo_meta import shot_time_label, sort_photos_by_shot_time
from s3_photos import cache_photo

url = next(
    os.environ[k]
    for k in ("DATABASE_URL", "AGENT1_DATABASE_URL", "AGENT1_DB_URL")
    if os.environ.get(k)
)
day = "2026-08-03"
conn = psycopg.connect(url, row_factory=dict_row)
cur = conn.cursor()

cur.execute(
    "SELECT order_id FROM agent_decisions WHERE day=%s::date AND checklist='1а' "
    "AND stage2->>'status'='ok' ORDER BY random() LIMIT 20",
    (day,),
)
orders = [r["order_id"] for r in cur.fetchall()]


def items_for(oid):
    cur.execute(
        "SELECT photo_id, blob_key, photo_url, filename, ptype FROM photos_day "
        "WHERE day=%s::date AND order_id=%s",
        (day, oid),
    )
    out = []
    for ph in sort_photos_by_shot_time([dict(r) for r in cur.fetchall()]):
        p = cache_photo(
            ph.get("blob_key"), photo_id=ph.get("photo_id"), day=day, photo_url=ph.get("photo_url")
        )
        if p:
            out.append(
                {"path": p, "time": shot_time_label(ph.get("filename")), "kind": ph.get("ptype")}
            )
    return out


def meta_for(oid):
    cur.execute(
        "SELECT order_id, state, site_address, site_stype, waste_type_name, fail_reason, "
        "report_comment FROM orders_day WHERE day=%s::date AND order_id=%s",
        (day, oid),
    )
    r = cur.fetchone()
    d = dict(r) if r else {"order_id": oid}
    d["day"] = day
    return d


NOTES = (
    ("с оговоркой про О3/А4/Н5", stage2.FALLBACK_NOTE),
    ("без оговорки", "Если вопрос неприменим — ответь 0."),
)
res = {name: {"fake": 0, "a3": 0, "n": 0} for name, _ in NOTES}
for oid in orders:
    line = f"{oid:>10}"
    items = items_for(oid)
    if not items:
        continue
    for name, note in NOTES:
        stage2.FALLBACK_NOTE = note
        try:
            r = stage2.call_vision(stage2.Checklist.KP, items, meta_for(oid))
        except Exception as exc:
            line += f" | ERR {str(exc)[:14]}"
            continue
        a = r.get("answers") or {}
        res[name]["n"] += 1
        res[name]["fake"] += 1 if str(a.get("О3")) == "0" else 0
        res[name]["a3"] += 1 if str(a.get("А3")) == "1" else 0
        line += f" | {name[:12]}: О3={a.get('О3')} А3={a.get('А3')}"
    print(line)

print("\nитого (О3=0 у модели = «подделка», это ложное нарушение):")
for name, _ in NOTES:
    r = res[name]
    if r["n"]:
        print(f"  {name:<26} О3=подделка {r['fake']}/{r['n']} ({100.0*r['fake']/r['n']:.0f}%)"
              f"   А3=1 {r['a3']}/{r['n']} ({100.0*r['a3']/r['n']:.0f}%)")
conn.close()
PY
