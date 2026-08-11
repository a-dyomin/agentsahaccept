#!/bin/bash
set -eu
set -a
# shellcheck disable=SC1091
source /home/admin-akea/agent1/.env
set +a
cd /home/admin-akea/agent1/app
../venv/bin/python <<'PY'
"""Компромисс: ярлыки на кадрах vs подсказка только в А3 — что лучше для А3 и О3."""
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

# случайная выборка + пара «пустой бак» глазами
FIXED = [19298843, 19298295]
cur.execute(
    "SELECT order_id FROM agent_decisions WHERE day=%s::date AND checklist='1а' "
    "AND stage2->>'status'='ok' AND order_id <> ALL(%s) ORDER BY random() LIMIT 16",
    (day, FIXED),
)
orders = FIXED + [r["order_id"] for r in cur.fetchall()]

BASE = stage2.questions_for
# подсказка только в А3, кадры без ярлыков
A3_HINT = BASE("1а").replace(
    "А3: есть снимок, где видно, что баки пустые ИЛИ отходы с точки убраны? "
    "Если по снимкам нельзя судить о содержимом — 0.",
    "А3: есть снимок ПОСЛЕ вывоза (последние по времени), где баки пустые "
    "ИЛИ отходы с точки убраны? Если по снимкам нельзя судить о содержимом — 0. "
    "Сравни с более ранними кадрами.",
)


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


# вернём простую fallback-строку, как в успешном прогоне
stage2.FALLBACK_NOTE = "Если вопрос неприменим — ответь 0."

VARIANTS = (
    ("кадры+ярлыки", True, BASE),
    ("без ярлыков", False, BASE),
    ("подсказка в А3", False, lambda cl: A3_HINT if cl == "1а" else BASE(cl)),
)
print(f"{'заявка':>10} | " + " | ".join(f"{n:^14}" for n, _, _ in VARIANTS))
print("-" * 70)
agg = {n: {"a3": 0, "ok_o3": 0, "n": 0} for n, _, _ in VARIANTS}
for oid in orders:
    cells = []
    for name, kind, qs in VARIANTS:
        stage2.questions_for = qs
        items = items_for(oid, kind)
        if not items:
            cells.append("нет фото")
            continue
        try:
            r = stage2.call_vision(stage2.Checklist.KP, items, meta_for(oid))
        except Exception as exc:
            cells.append(f"ERR {str(exc)[:10]}")
            continue
        a = r.get("answers") or {}
        agg[name]["n"] += 1
        agg[name]["a3"] += 1 if str(a.get("А3")) == "1" else 0
        agg[name]["ok_o3"] += 1 if str(a.get("О3")) == "1" else 0
        cells.append(f"О3={a.get('О3')} А3={a.get('А3')}")
    mark = " *" if oid in FIXED else ""
    print(f"{oid:>10} | " + " | ".join(f"{c:^14}" for c in cells) + mark)

print("-" * 70)
print("О3=1 подлинные / А3=1 пусто:")
for name, _, _ in VARIANTS:
    r = agg[name]
    if r["n"]:
        print(f"  {name:<14} О3ok {r['ok_o3']:2d}/{r['n']} ({100.0*r['ok_o3']/r['n']:3.0f}%)"
              f"   А3={r['a3']:2d}/{r['n']} ({100.0*r['a3']/r['n']:3.0f}%)")
conn.close()
PY
