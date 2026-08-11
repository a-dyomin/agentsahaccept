#!/bin/bash
set -eu
set -a
# shellcheck disable=SC1091
source /home/admin-akea/agent1/.env
set +a
cd /home/admin-akea/agent1/app
../venv/bin/python <<'PY'
"""Проверка: ушли ли ложный «дубль» (О3) в 1а и «помеха не видна» (О1) в чек-листе 2."""
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

CL = {"1а": stage2.Checklist.KP, "2": stage2.Checklist.NON_PICKUP}


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
                {
                    "path": p,
                    "time": shot_time_label(ph.get("filename")),
                    "kind": ph.get("ptype"),
                }
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


for cl, code, cond, title in (
    ("1а", "О3", "stage2->'answers'->>'О3'='1'", "1а: было О3=подделка"),
    ("2", "О1", "stage2->'answers'->>'О1'='0'", "2: было О1=0 «помеха не видна»"),
):
    cur.execute(
        f"SELECT order_id FROM agent_decisions WHERE day=%s::date AND checklist=%s AND {cond} "
        "ORDER BY random() LIMIT 8",
        (day, cl),
    )
    orders = [r["order_id"] for r in cur.fetchall()]
    print(f"\n=== {title} ({len(orders)} заявок) ===")
    fixed = 0
    for oid in orders:
        items = items_for(oid)
        if not items:
            print(f"  {oid}: нет фото")
            continue
        try:
            r = stage2.call_vision(CL[cl], items, meta_for(oid))
        except Exception as exc:
            print(f"  {oid}: ERR {str(exc)[:40]}")
            continue
        a = r.get("answers") or {}
        val = a.get(code)
        ok = (code == "О3" and str(val) == "1") or (code == "О1" and str(val) == "1")
        fixed += 1 if ok else 0
        note = "исправлено" if ok else "осталось"
        print(f"  {oid}: {code}={val} ({note})  {str(r.get('comment'))[:70]}")
    print(f"  итого исправлено: {fixed} из {len(orders)}")
    print("  (О3=1 у модели = подлинные, О1=1 = кадры пригодны)")
conn.close()
PY
