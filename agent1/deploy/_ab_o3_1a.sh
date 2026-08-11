#!/bin/bash
set -eu
set -a
# shellcheck disable=SC1091
source /home/admin-akea/agent1/.env
set +a
cd /home/admin-akea/agent1/app
../venv/bin/python <<'PY'
"""Что именно даёт О3=подделка в 1а: ярлыки кадров или формулировка вопроса."""
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
    "AND stage2->'answers'->>'О3'='1' ORDER BY random() LIMIT 8",
    (day,),
)
orders = [r["order_id"] for r in cur.fetchall()]

BASE = stage2.questions_for
O3_NOW = [ln for ln in BASE("1а").splitlines() if ln.startswith("О3:")][0]
O3_SHORT = "О3: снимки подлинные? 0 только если это скрин карты/экрана или явно чужое место."
SHORT_TEXT = BASE("1а").replace(O3_NOW, O3_SHORT)


def short_questions(cl):
    return SHORT_TEXT if cl == "1а" else BASE(cl)


def items_for(oid, with_kind):
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
            it = {"path": p, "time": shot_time_label(ph.get("filename"))}
            if with_kind:
                it["kind"] = ph.get("ptype")
            out.append(it)
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
    ("ярлыки+текущий О3", True, BASE),
    ("без ярлыков", False, BASE),
    ("ярлыки+короткий О3", True, short_questions),
)
print(f"{'заявка':>10} | " + " | ".join(f"{n:^20}" for n, _, _ in VARIANTS))
print("-" * 80)
agg = {n: 0 for n, _, _ in VARIANTS}
for oid in orders:
    cells = []
    for name, kind, qs in VARIANTS:
        stage2.questions_for = qs
        try:
            r = stage2.call_vision(stage2.Checklist.KP, items_for(oid, kind), meta_for(oid))
            a = r.get("answers") or {}
            cells.append(f"О3={a.get('О3')} А3={a.get('А3')}")
            if str(a.get("О3")) == "1":
                agg[name] += 1
        except Exception as exc:
            cells.append(f"ERR {str(exc)[:12]}")
    print(f"{oid:>10} | " + " | ".join(f"{c:^20}" for c in cells))
print("-" * 80)
print("О3=1 (подлинные, нарушения нет) из", len(orders), ":",
      "  ".join(f"{n}={v}" for n, v in agg.items()))
conn.close()
PY
