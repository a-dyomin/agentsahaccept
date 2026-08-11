#!/bin/bash
set -eu
set -a
# shellcheck disable=SC1091
source /home/admin-akea/agent1/.env
set +a
cd /home/admin-akea/agent1/app
../venv/bin/python <<'PY'
"""Ярлыки кадров + только О3 позитивный (как в успешном прогоне) vs О3+А4."""
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

FIXED = [19298843, 19298295]
cur.execute(
    "SELECT order_id FROM agent_decisions WHERE day=%s::date AND checklist='1а' "
    "AND stage2->>'status'='ok' AND order_id <> ALL(%s) ORDER BY random() LIMIT 12",
    (day, FIXED),
)
orders = FIXED + [r["order_id"] for r in cur.fetchall()]

BASE = stage2.questions_for
# А4 как в успешном прогоне (негативная полярность)
A4_OLD = (
    "А4: на самых поздних по времени пригодных снимках остатки отходов в баках "
    "(1=да, нарушение)?"
)
TEXT_A4OLD = BASE("1а").replace(
    "А4: на самых поздних снимках баки и точка без остатков отходов? "
    "0, если на них отходы остались.",
    A4_OLD,
)

stage2.FALLBACK_NOTE = "Если вопрос неприменим — ответь 0."


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
    ("О3+А4 позитив", BASE),
    ("А4 негатив(старое)", lambda cl: TEXT_A4OLD if cl == "1а" else BASE(cl)),
)
print(f"{'заявка':>10} | " + " | ".join(f"{n:^20}" for n, _ in VARIANTS))
print("-" * 60)
agg = {n: {"a3": 0, "ok_o3": 0, "n": 0} for n, _ in VARIANTS}
for oid in orders:
    cells = []
    items = items_for(oid)
    if not items:
        continue
    for name, qs in VARIANTS:
        stage2.questions_for = qs
        try:
            r = stage2.call_vision(stage2.Checklist.KP, items, meta_for(oid))
        except Exception as exc:
            cells.append(f"ERR {str(exc)[:12]}")
            continue
        a = r.get("answers") or {}
        agg[name]["n"] += 1
        agg[name]["a3"] += 1 if str(a.get("А3")) == "1" else 0
        agg[name]["ok_o3"] += 1 if str(a.get("О3")) == "1" else 0
        cells.append(f"О3={a.get('О3')} А3={a.get('А3')} А4={a.get('А4')}")
    mark = " *" if oid in FIXED else ""
    print(f"{oid:>10} | " + " | ".join(f"{c:^20}" for c in cells) + mark)

print("-" * 60)
for name, _ in VARIANTS:
    r = agg[name]
    if r["n"]:
        print(f"  {name:<20} О3ok {r['ok_o3']:2d}/{r['n']} ({100.0*r['ok_o3']/r['n']:3.0f}%)"
              f"   А3={r['a3']:2d}/{r['n']} ({100.0*r['a3']/r['n']:3.0f}%)")
conn.close()
PY
