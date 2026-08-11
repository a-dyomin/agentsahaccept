#!/bin/bash
set -eu
set -a
# shellcheck disable=SC1091
source /home/admin-akea/agent1/.env
set +a
/home/admin-akea/agent1/venv/bin/python <<'PY'
import json
import os
from collections import Counter

import psycopg
from psycopg.rows import dict_row

live = json.load(open("/tmp/human_labels_live.json", encoding="utf-8"))
url = next(
    os.environ[k]
    for k in ("DATABASE_URL", "AGENT1_DATABASE_URL", "AGENT1_DB_URL")
    if os.environ.get(k)
)


def hb(bs):
    if not bs or bs in {"not_checked", "processed_by_provider"}:
        return None
    x = str(bs).lower()
    if x in {"accepted", "принят", "нарушение"}:
        return "НАРУШЕНИЕ"
    if x in {"rejected", "отклонён", "отклонен", "не нарушение", "не_нарушение"}:
        return "ЧИСТО"
    return None


def ab(itog):
    if not itog:
        return None
    if itog in {"НЕ ВЗЯТА В РАБОТУ", "НЕ ПРОВЕРЯЕТСЯ", "СМЕНА НЕ ВЫШЛА", "ПЕРЕДАНА"}:
        return "OUT"
    if itog == "К ЧЕЛОВЕКУ":
        return "HUMAN"
    if itog.startswith("НАРУШЕНИЕ"):
        return "НАРУШЕНИЕ"
    if itog == "ЧИСТО":
        return "ЧИСТО"
    return None


fps = []
comp = []
agrees_nopickup = 0
total_nopickup_comp = 0

with psycopg.connect(url, row_factory=dict_row) as conn:
    cur = conn.cursor()
    for day, humans in live.items():
        hmap = {int(r["order_id"]): r for r in humans}
        cur.execute(
            """
            SELECT ad.order_id, ad.itog, ad.za_chto, ad.checklist,
                   o.state, o.track_flag, o.time_flag, o.foto_doezd_flag, o.geo_flag,
                   o.has_report, o.fail_reason,
                   COALESCE(ad.stage2->>'photo_verdict','') pv
            FROM agent_decisions ad
            LEFT JOIN orders_day o ON o.day=ad.day AND o.order_id=ad.order_id
            WHERE ad.day=%s::date
            """,
            (day,),
        )
        for a in cur.fetchall():
            h = hmap.get(int(a["order_id"]))
            if not h:
                continue
            H = hb(h.get("breach_state"))
            A = ab(a["itog"])
            if H is None or A in (None, "OUT", "HUMAN"):
                continue
            st = a.get("state") or h.get("state")
            row = {
                "day": day,
                "order_id": a["order_id"],
                "A": A,
                "H": H,
                "itog": a["itog"],
                "za_chto": a.get("za_chto") or "",
                "state": st,
                "checklist": a.get("checklist") or "",
                "track": a.get("track_flag"),
                "time": a.get("time_flag"),
                "foto_doezd": a.get("foto_doezd_flag"),
                "geo": a.get("geo_flag"),
                "has_report": a.get("has_report"),
                "fail_reason": a.get("fail_reason"),
                "pv": a.get("pv"),
                "note": (h.get("accept_note") or h.get("regoper_note") or "")[:200],
            }
            comp.append(row)
            if st == "canceled_by_driver":
                total_nopickup_comp += 1
                if A == H:
                    agrees_nopickup += 1
            if A == "НАРУШЕНИЕ" and H == "ЧИСТО":
                fps.append(row)

print("FP_TOTAL", len(fps))
print(
    "NOPICKUP_COMP",
    total_nopickup_comp,
    "agree",
    agrees_nopickup,
    "pct",
    round(100 * agrees_nopickup / total_nopickup_comp, 1) if total_nopickup_comp else None,
)

tok = Counter()
for f in fps:
    for t in [x.strip() for x in (f["za_chto"] or "").split(";")]:
        if t:
            tok[t.split(",")[0][:40]] += 1
print("ZA_CHTO_TOKENS", tok.most_common(20))

print("FLAGS among FP")
for k in ("track", "time", "foto_doezd", "geo", "has_report"):
    print(k, Counter(str(f.get(k)) for f in fps).most_common())

kw = Counter()
for f in fps:
    n = (f["note"] or "").lower()
    for word, label in [
        ("отработан", "точка_отработана"),
        ("трек", "упоминание_трека"),
        ("автомоб", "автомобиль"),
        ("проезд", "проезд"),
        ("закрыт", "закрыт_проезд"),
        ("размыт", "дорога"),
        ("помех", "помеха"),
        ("контейнер", "контейнер"),
        ("невозможно", "невозможно"),
        ("нет наруш", "явное_не_нарушение"),
    ]:
        if word in n:
            kw[label] += 1
    if not n.strip():
        kw["empty_note"] += 1
print("NOTE_KEYWORDS", kw.most_common())


def simulate(predicate, name):
    kept = [c for c in comp if not predicate(c)]
    agree = sum(1 for c in kept if c["A"] == c["H"])
    n = len(kept)
    rem = [c for c in comp if predicate(c)]
    rem_fp = sum(1 for c in rem if c["A"] == "НАРУШЕНИЕ" and c["H"] == "ЧИСТО")
    rem_ok = sum(1 for c in rem if c["A"] == c["H"])
    print(
        f"GATE {name}: removed={len(rem)} (FP_in_removed={rem_fp}, agree_in_removed={rem_ok}) "
        f"comparable={n} agreement={round(100 * agree / n, 1) if n else None}%"
    )


print(
    "BASE comparable",
    len(comp),
    "agree",
    round(100 * sum(c["A"] == c["H"] for c in comp) / len(comp), 1),
)
simulate(lambda c: c["checklist"] == "2" and c["A"] == "НАРУШЕНИЕ", "escalate_checklist2_violations")
simulate(
    lambda c: c["state"] == "canceled_by_driver" and "фото" in (c["itog"] or ""),
    "escalate_nopickup_photo_violations",
)
simulate(
    lambda c: c["state"] == "canceled_by_driver" and c["A"] == "НАРУШЕНИЕ",
    "escalate_all_nopickup_violations",
)
simulate(lambda c: "фото" in (c["itog"] or ""), "escalate_all_photo_violations")
simulate(
    lambda c: c["state"] == "canceled_by_driver"
    and c["A"] == "НАРУШЕНИЕ"
    and (str(c.get("foto_doezd")) in {"0", "ND", "None", ""} or c.get("pv") == "НАРУШЕНИЕ"),
    "escalate_nopickup_weak_photo",
)

json.dump(
    {
        "fps": [
            {k: f[k] for k in ("day", "order_id", "itog", "za_chto", "state", "note", "checklist")}
            for f in fps[:60]
        ],
        "fp_total": len(fps),
        "za_chto": tok.most_common(20),
        "notes": kw.most_common(),
        "nopickup_agree_pct": round(100 * agrees_nopickup / total_nopickup_comp, 1)
        if total_nopickup_comp
        else None,
    },
    open("/tmp/fp_deep.json", "w", encoding="utf-8"),
    ensure_ascii=False,
    indent=2,
)
print("WROTE /tmp/fp_deep.json")
PY
