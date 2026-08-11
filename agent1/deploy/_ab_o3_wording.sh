#!/bin/bash
set -eu
set -a
# shellcheck disable=SC1091
source /home/admin-akea/agent1/.env
set +a
cd /home/admin-akea/agent1/app
../venv/bin/python <<'PY'
"""О3 в 1а: прежняя формулировка против сегодняшней добавки про «дубль»."""
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

BASE = stage2.questions_for
NEW_O3 = [ln for ln in BASE("1а").splitlines() if ln.startswith("О3:")][0]
OLD_O3 = (
    "О3: снимки подлинные — настоящие фото площадки с места? "
    "0, если это скрин карты/экрана, дубль одного кадра или съёмка не с места."
)
NO_DUP_O3 = (
    "О3: снимки подлинные — настоящие фото площадки с места? "
    "0, если это скрин карты/экрана или съёмка не с места."
)
TEXT_OLD = BASE("1а").replace(NEW_O3, OLD_O3)
TEXT_NODUP = BASE("1а").replace(NEW_O3, NO_DUP_O3)


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


VARIANTS = (
    ("сегодняшняя", BASE("1а")),
    ("прежняя", TEXT_OLD),
    ("без слова «дубль»", TEXT_NODUP),
)
res = {n: {"fake": 0, "a3": 0, "n": 0} for n, _ in VARIANTS}
for oid in orders:
    items = items_for(oid)
    if not items:
        continue
    cells = []
    for name, text in VARIANTS:
        stage2.questions_for = lambda cl, _t=text: _t if cl == "1а" else BASE(cl)
        try:
            r = stage2.call_vision(stage2.Checklist.KP, items, meta_for(oid))
        except Exception as exc:
            cells.append(f"ERR {str(exc)[:10]}")
            continue
        a = r.get("answers") or {}
        res[name]["n"] += 1
        res[name]["fake"] += 1 if str(a.get("О3")) == "0" else 0
        res[name]["a3"] += 1 if str(a.get("А3")) == "1" else 0
        cells.append(f"О3={a.get('О3')} А3={a.get('А3')}")
    print(f"{oid:>10} | " + " | ".join(f"{c:^12}" for c in cells))

print("\nО3=0 у модели = «подделка» = ложное нарушение:")
for name, _ in VARIANTS:
    r = res[name]
    if r["n"]:
        print(f"  {name:<20} подделка {r['fake']:2d}/{r['n']} ({100.0*r['fake']/r['n']:3.0f}%)"
              f"   А3=1 {r['a3']:2d}/{r['n']} ({100.0*r['a3']/r['n']:3.0f}%)")
conn.close()
PY
