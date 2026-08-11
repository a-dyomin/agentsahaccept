#!/bin/bash
set -eu
set -a
# shellcheck disable=SC1091
source /home/admin-akea/agent1/.env
set +a
cd /home/admin-akea/agent1/app
../venv/bin/python <<'PY'
"""A/B: gpt-4o-mini vs gpt-4.1 на заявках, где А3 сейчас 0."""
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

FIXED = [19298843, 19298295]  # глазами: бак пустой на ПОСЛЕ
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


MODELS = (
    ("4o-mini", "gpt-4o-mini", 0.15, 0.60),
    ("4.1", "gpt-4.1", 2.00, 8.00),
)
print(f"{'заявка':>10} | " + " | ".join(f"{n:^16}" for n, *_ in MODELS))
print("-" * 55)
agg = {n: {"a3": 0, "o3ok": 0, "n": 0, "usd": 0.0} for n, *_ in MODELS}
for oid in orders:
    items = items_for(oid)
    if not items:
        continue
    cells = []
    for name, model, pin, pout in MODELS:
        stage2.VISION_MODEL = model
        stage2.VISION_INPUT_PER_M = pin
        stage2.VISION_OUTPUT_PER_M = pout
        try:
            r = stage2.call_vision(stage2.Checklist.KP, items, meta_for(oid))
        except Exception as exc:
            cells.append(f"ERR {str(exc)[:12]}")
            continue
        a = r.get("answers") or {}
        cost = float((r.get("usage") or {}).get("cost_usd") or 0)
        agg[name]["n"] += 1
        agg[name]["a3"] += 1 if str(a.get("А3")) == "1" else 0
        agg[name]["o3ok"] += 1 if str(a.get("О3")) == "1" else 0
        agg[name]["usd"] += cost
        cells.append(f"О3={a.get('О3')} А3={a.get('А3')}")
    mark = " *" if oid in FIXED else ""
    print(f"{oid:>10} | " + " | ".join(f"{c:^16}" for c in cells) + mark)

print("-" * 55)
for name, *_ in MODELS:
    r = agg[name]
    if r["n"]:
        print(
            f"  {name:<8} А3=1 {r['a3']}/{r['n']} ({100*r['a3']/r['n']:.0f}%)  "
            f"О3ok {r['o3ok']}/{r['n']} ({100*r['o3ok']/r['n']:.0f}%)  "
            f"${r['usd']:.3f}"
        )
print("  * = глазами пустой бак на ПОСЛЕ")
conn.close()
PY
