#!/bin/bash
set -eu
set -a
# shellcheck disable=SC1091
source /home/admin-akea/agent1/.env
set +a
cd /home/admin-akea/agent1/app
../venv/bin/python <<'PY'
"""A/B: помогает ли пометка кадров ДО/ПОСЛЕ (ptype из Гретты) вопросу А3."""
import os
import psycopg
from psycopg.rows import dict_row

import stage2
from photo_meta import shot_time_label, sort_photos_by_shot_time
from s3_photos import cache_photo

url = None
for k in ("DATABASE_URL", "AGENT1_DATABASE_URL", "AGENT1_DB_URL"):
    if os.environ.get(k):
        url = os.environ[k]
        break
day = "2026-08-03"
conn = psycopg.connect(url, row_factory=dict_row)
cur = conn.cursor()

# 19298843 — глазами проверено: на позднем кадре бак пустой, А3 обязан быть 1
FIXED = [19298843, 19298295]
cur.execute(
    """
    SELECT order_id FROM agent_decisions
    WHERE day=%s::date AND checklist='1а' AND stage2->>'status'='ok'
      AND stage2->'answers'->>'А3'='0' AND order_id <> ALL(%s)
    ORDER BY random() LIMIT 10
    """,
    (day, FIXED),
)
orders = FIXED + [r["order_id"] for r in cur.fetchall()]

BASE = stage2.questions_for
ALT_TEXT = BASE("1а").replace(
    "А3: есть снимок, где видно, что баки пустые ИЛИ отходы с точки убраны? "
    "Если по снимкам нельзя судить о содержимом — 0.",
    "А3: посмотри на кадры ПОСЛЕ вывоза. Ответь 1, если на них баки пустые, "
    "или отходов заметно меньше, чем на кадрах ДО, или точка убрана. "
    "Ответь 0 только если после вывоза осталось столько же отходов.",
)

def alt_questions(cl):
    return ALT_TEXT if cl == "1а" else BASE(cl)

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
        "SELECT order_id, state, site_address, site_stype, waste_type_name, fail_reason, report_comment "
        "FROM orders_day WHERE day=%s::date AND order_id=%s",
        (day, oid),
    )
    r = cur.fetchone()
    d = dict(r) if r else {"order_id": oid}
    d["day"] = day
    return d

VARIANTS = (
    ("A", False, BASE),          # как сейчас
    ("D", True, BASE),           # + пометка ДО/ПОСЛЕ
    ("E", True, alt_questions),  # + пометка и переписанный А3
)

print(f"{'заявка':>10} | {'A сейчас':^12} | {'D ДО/ПОСЛЕ':^12} | {'E D+текст':^12}")
print("-" * 58)
agg = {t: 0 for t, _, _ in VARIANTS}
cost = 0.0
for oid in orders:
    row = {}
    for tag, kind, qs in VARIANTS:
        stage2.questions_for = qs
        try:
            items = items_for(oid, kind)
            if not items:
                row[tag] = "нет фото"
                continue
            r = stage2.call_vision(stage2.Checklist.KP, items, meta_for(oid))
            a = r.get("answers") or {}
            row[tag] = f"А2={a.get('А2')} А3={a.get('А3')}"
            if str(a.get("А3")) == "1":
                agg[tag] += 1
            cost += float((r.get("usage") or {}).get("cost_usd") or 0)
        except Exception as exc:
            row[tag] = f"ERR {str(exc)[:14]}"
    mark = " <= пустой бак виден" if oid in FIXED else ""
    print(f"{oid:>10} | {row.get('A',''):^12} | {row.get('D',''):^12} | {row.get('E',''):^12}{mark}")

print("-" * 58)
print(f"А3=1 из {len(orders)}:  A={agg['A']}  D={agg['D']}  E={agg['E']}")
print(f"стоимость: ${cost:.4f}")
conn.close()
PY
