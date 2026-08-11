#!/bin/bash
set -eu
set -a
# shellcheck disable=SC1091
source /home/admin-akea/agent1/.env
set +a
cd /home/admin-akea/agent1/app
../venv/bin/python <<'PY'
"""A/B: почему А3 почти всегда 0 — мало разрешения или формулировка?"""
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

cur.execute(
    """
    SELECT order_id, stage1, stage2->'answers' ans
    FROM agent_decisions
    WHERE day=%s::date AND checklist='1а' AND stage2->>'status'='ok'
      AND stage2->'answers'->>'А2'='1' AND stage2->'answers'->>'А3'='0'
    ORDER BY random() LIMIT 10
    """,
    (day,),
)
orders = cur.fetchall()
print("выборка:", [o["order_id"] for o in orders])

def photos_for(oid):
    cur.execute(
        "SELECT photo_id, blob_key, photo_url, filename FROM photos_day WHERE day=%s::date AND order_id=%s",
        (day, oid),
    )
    return [dict(r) for r in cur.fetchall()]

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

# альтернативная формулировка А3: явное сравнение раннего и позднего кадра
BASE = stage2.questions_for
ALT_TEXT = BASE("1а").replace(
    "А3: есть снимок, где видно, что баки пустые ИЛИ отходы с точки убраны? "
    "Если по снимкам нельзя судить о содержимом — 0.",
    "А3: сравни САМЫЙ РАННИЙ и САМЫЙ ПОЗДНИЙ снимок. Ответь 1, если на позднем "
    "отходов явно меньше или их нет: баки пустые, либо мусор с точки убран, либо "
    "площадка стала чище. Ответь 0 только если поздний кадр не отличается от раннего "
    "или поздних кадров нет.",
)

def alt_questions(cl):
    return ALT_TEXT if cl == "1а" else BASE(cl)

def run(oid, detail, questions):
    stage2.VISION_DETAIL = detail
    stage2.questions_for = questions
    phs = sort_photos_by_shot_time(photos_for(oid))
    items = []
    for ph in phs:
        p = cache_photo(
            ph.get("blob_key"),
            photo_id=ph.get("photo_id"),
            day=day,
            photo_url=ph.get("photo_url"),
        )
        if p:
            items.append({"path": p, "time": shot_time_label(ph.get("filename"))})
    if not items:
        return None
    return stage2.call_vision(stage2.Checklist.KP, items, meta_for(oid))

print(f"\n{'заявка':>10} | {'A: как сейчас':^14} | {'B: detail=high':^14} | {'C: А3 сравнение':^16}")
print("-" * 66)
agg = {"A": 0, "B": 0, "C": 0}
cost = 0.0
for o in orders:
    oid = o["order_id"]
    out = {}
    for tag, detail, qs in (("A", "low", BASE), ("B", "high", BASE), ("C", "low", alt_questions)):
        try:
            r = run(oid, detail, qs)
            if not r:
                out[tag] = "нет фото"
                continue
            a = r.get("answers") or {}
            out[tag] = f"А2={a.get('А2')} А3={a.get('А3')}"
            if str(a.get("А3")) == "1":
                agg[tag] += 1
            cost += float((r.get("usage") or {}).get("cost_usd") or 0)
        except Exception as exc:
            out[tag] = f"ERR {str(exc)[:20]}"
    print(f"{oid:>10} | {out.get('A',''):^14} | {out.get('B',''):^14} | {out.get('C',''):^16}")

print("-" * 66)
print(f"А3=1 из {len(orders)}:  A(сейчас)={agg['A']}   B(high)={agg['B']}   C(сравнение)={agg['C']}")
print(f"стоимость эксперимента: ${cost:.4f}")
conn.close()
PY
