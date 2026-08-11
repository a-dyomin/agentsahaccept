#!/bin/bash
# Pull live Greta human accept labels for days already processed by agent1,
# compare with agent_decisions, write JSON report.
set -eu
set -a
# shellcheck disable=SC1091
source /home/admin-akea/agent1/.env
set +a

OUT_JSON="${1:-/tmp/agent1_human_review.json}"
DAYS_CSV="${2:-}"  # optional override: 2026-08-02,2026-08-03,...

KEY="${GRETA_SSH_KEY:-/home/admin-akea/.ssh/greta_ro}"
HOST="${GRETA_SSH_HOST:-greta.akea-ds.ru}"
PORT="${GRETA_SSH_PORT:-34023}"
USER="${GRETA_SSH_USER:-gretaadmin}"

# 1) Resolve days with agent decisions (prefer fully/mostly done)
/home/admin-akea/agent1/venv/bin/python <<PY > /tmp/_days_for_review.txt
import os, psycopg
from psycopg.rows import dict_row
url = next(os.environ[k] for k in ("DATABASE_URL","AGENT1_DATABASE_URL","AGENT1_DB_URL") if os.environ.get(k))
override = "${DAYS_CSV}".strip()
with psycopg.connect(url, row_factory=dict_row) as conn:
    cur = conn.cursor()
    if override:
        days = [d.strip() for d in override.split(",") if d.strip()]
    else:
        cur.execute("""
          SELECT ad.day::text d, COUNT(*)::int decisions,
                 COALESCE((
                   SELECT COUNT(*)::int FROM jobs j
                   JOIN runs r ON r.id=j.run_id
                   WHERE r.day=ad.day AND j.status='queued'
                 ),0) queued
          FROM agent_decisions ad
          GROUP BY 1
          ORDER BY 1
        """)
        days = []
        for r in cur.fetchall():
            # include day if mostly processed (queued < 500) OR has >= 1000 decisions
            if r["queued"] < 500 or r["decisions"] >= 1000:
                days.append(r["d"])
    print(",".join(days))
    for d in days:
        print(d, file=__import__("sys").stderr)
print("DAYS", open("/tmp/_days_for_review.txt").read().strip(), file=__import__("sys").stderr)
PY

DAYS=$(cat /tmp/_days_for_review.txt | head -1)
echo "Review days: $DAYS"

# 2) Lightweight Greta rails runner: dump human labels only
cat > /tmp/_greta_human_labels.rb <<'RUBY'
# frozen_string_literal: true
require "json"
days = (ARGV[0] || "").split(",").map { |d| Date.parse(d.strip) }
raise "no days" if days.empty?
out = {}
days.each do |day|
  rows = Order.kept.where(date: day).pluck(
    :id, :state, :breach_state, :breach_accept_note, :breach_accept_regoper_note, :schedule_id
  )
  out[day.to_s] = rows.map do |id, state, bs, note, reg, sid|
    {
      "order_id" => id,
      "state" => state,
      "breach_state" => bs,
      "accept_note" => note,
      "regoper_note" => reg,
      "schedule_id" => sid,
    }
  end
end
puts JSON.generate(out)
RUBY

scp -i "$KEY" -P "$PORT" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
  /tmp/_greta_human_labels.rb "${USER}@${HOST}:~/agent1_export/_greta_human_labels.rb"

ssh -i "$KEY" -p "$PORT" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=30 \
  "${USER}@${HOST}" bash -s -- "$DAYS" <<'REMOTE'
set -eu
DAYS="$1"
sed -i 's/\r$//' ~/agent1_export/_greta_human_labels.rb
cd ~/greta-backend/current
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
eval "$(rbenv init -)"
# timeout generous: pluck only, no tracks
timeout 300 env RAILS_ENV=production bundle exec rails runner \
  ~/agent1_export/_greta_human_labels.rb "$DAYS" > /tmp/human_labels_live.json
wc -c /tmp/human_labels_live.json
python3 - <<'PY'
import json
d=json.load(open("/tmp/human_labels_live.json"))
print({k: len(v) for k,v in d.items()})
# breach_state distribution
from collections import Counter
for day, rows in sorted(d.items()):
    c=Counter((r.get("breach_state") or "null") for r in rows)
    print(day, dict(c.most_common(12)))
PY
REMOTE

scp -i "$KEY" -P "$PORT" -o IdentitiesOnly=yes -o BatchMode=yes \
  "${USER}@${HOST}:/tmp/human_labels_live.json" /tmp/human_labels_live.json

# 3) Compare with agent decisions
/home/admin-akea/agent1/venv/bin/python <<'PY'
import json, os, re
from collections import Counter, defaultdict
import psycopg
from psycopg.rows import dict_row

live = json.load(open("/tmp/human_labels_live.json", encoding="utf-8"))
url = next(os.environ[k] for k in ("DATABASE_URL","AGENT1_DATABASE_URL","AGENT1_DB_URL") if os.environ.get(k))

SKIP_HUMAN = {"not_checked", "processed_by_provider", "", None}
NIW = {"НЕ ВЗЯТА В РАБОТУ", "НЕ ПРОВЕРЯЕТСЯ", "СМЕНА НЕ ВЫШЛА", "ПЕРЕДАНА"}

def human_bucket(bs):
    if bs in SKIP_HUMAN or not bs:
        return None
    hb = str(bs).strip().lower()
    if hb in {"accepted", "принят", "нарушение"}:
        return "НАРУШЕНИЕ"
    if hb in {"rejected", "отклонён", "отклонен", "не нарушение", "не_нарушение"}:
        return "ЧИСТО"
    return f"OTHER:{bs}"

def agent_bucket(itog):
    if not itog:
        return None
    if itog in NIW:
        return "OUT_OF_SCOPE"
    if itog == "К ЧЕЛОВЕКУ":
        return "К ЧЕЛОВЕКУ"
    if itog.startswith("НАРУШЕНИЕ"):
        return "НАРУШЕНИЕ"
    if itog == "ЧИСТО":
        return "ЧИСТО"
    return f"OTHER:{itog}"

def note_class(note):
    n = (note or "").strip().lower()
    if not n:
        return "empty"
    if "не наруш" in n or "не_наруш" in n:
        return "не_нарушение"
    if "график" in n or "опоздан" in n or "время" in n:
        return "график"
    if "фото" in n or "гео" in n or "трек" in n or "площадк" in n:
        return "фото_гео"
    if "не взят" in n or "не вышл" in n:
        return "охват"
    return "other"

report = {
    "generated_at": __import__("datetime").datetime.utcnow().isoformat() + "Z",
    "days": {},
    "totals": {},
    "mismatch_classes": {},
    "improvement_signals": {},
}

with psycopg.connect(url, row_factory=dict_row) as conn:
    cur = conn.cursor()
    all_comp = []
    mismatch_rows = []
    for day, humans in sorted(live.items()):
        hmap = {int(r["order_id"]): r for r in humans}
        cur.execute(
            """
            SELECT ad.order_id, ad.itog, ad.za_chto, ad.pometki,
                   COALESCE(ad.checklist, ad.stage2->>'checklist', '') checklist,
                   COALESCE(o.state, ad.stage1->>'state', '') AS state,
                   COALESCE(ad.stage2->>'status','') s2_status,
                   COALESCE(ad.stage2->>'photo_verdict','') photo_verdict,
                   COALESCE(ad.stage1->>'geo_flag', o.geo_flag::text, '') geo_flag,
                   COALESCE(ad.stage1->>'track_flag', o.track_flag::text, '') track_flag,
                   COALESCE(ad.stage1->>'time_flag', o.time_flag::text, '') time_flag
            FROM agent_decisions ad
            LEFT JOIN orders_day o ON o.day=ad.day AND o.order_id=ad.order_id
            WHERE ad.day=%s::date
            """,
            (day,),
        )
        agents = {int(r["order_id"]): r for r in cur.fetchall()}

        ingest_human = {}
        try:
            cur.execute(
                "SELECT order_id, breach_state FROM human_decisions WHERE day=%s::date",
                (day,),
            )
            ingest_human = {int(r["order_id"]): r["breach_state"] for r in cur.fetchall()}
        except Exception:
            conn.rollback()
        if not ingest_human:
            try:
                cur.execute(
                    "SELECT order_id, human_breach_state AS hs FROM orders_day WHERE day=%s::date",
                    (day,),
                )
                ingest_human = {int(r["order_id"]): r["hs"] for r in cur.fetchall()}
            except Exception:
                conn.rollback()
                ingest_human = {}

        day_stats = Counter()
        matrix = Counter()
        by_agent_itog = Counter()
        labeled = 0
        comparable = 0
        agree = 0
        fp = 0  # agent НАРУШЕНИЕ, human ЧИСТО
        fn = 0  # agent ЧИСТО, human НАРУШЕНИЕ
        escalated_ok = 0
        stale_vs_live = 0

        for oid, a in agents.items():
            h = hmap.get(oid)
            live_bs = (h or {}).get("breach_state")
            live_note = (h or {}).get("accept_note") or (h or {}).get("regoper_note")
            ingest_bs = ingest_human.get(oid)
            if ingest_bs and live_bs and str(ingest_bs) != str(live_bs):
                stale_vs_live += 1

            hb = human_bucket(live_bs)
            ab = agent_bucket(a["itog"])
            by_agent_itog[a["itog"] or "?"] += 1

            if hb is None:
                day_stats["human_pending"] += 1
                continue
            labeled += 1
            day_stats[f"human_{hb}"] += 1

            if ab == "OUT_OF_SCOPE":
                day_stats["agent_out_of_scope"] += 1
                continue
            if ab == "К ЧЕЛОВЕКУ":
                day_stats["agent_escalated"] += 1
                # if human decided, escalation is "sent to human correctly" for productivity
                escalated_ok += 1
                continue
            if ab and ab.startswith("OTHER"):
                day_stats["agent_other"] += 1
                continue

            comparable += 1
            matrix[(ab, hb)] += 1
            if ab == hb:
                agree += 1
                day_stats["agree"] += 1
            else:
                day_stats["disagree"] += 1
                if ab == "НАРУШЕНИЕ" and hb == "ЧИСТО":
                    fp += 1
                elif ab == "ЧИСТО" and hb == "НАРУШЕНИЕ":
                    fn += 1
                mismatch_rows.append({
                    "day": day,
                    "order_id": oid,
                    "agent_itog": a["itog"],
                    "agent_bucket": ab,
                    "human_breach_state": live_bs,
                    "human_bucket": hb,
                    "human_note": (live_note or "")[:240],
                    "note_class": note_class(live_note),
                    "state": a.get("state") or (h or {}).get("state"),
                    "za_chto": (a.get("za_chto") or "")[:160],
                    "checklist": a.get("checklist"),
                    "photo_verdict": a.get("photo_verdict"),
                    "s2_status": a.get("s2_status"),
                    "geo_flag": a.get("geo_flag"),
                    "track_flag": a.get("track_flag"),
                    "time_flag": a.get("time_flag"),
                    "class": (
                        "false_positive" if ab == "НАРУШЕНИЕ" and hb == "ЧИСТО" else
                        "missed_violation" if ab == "ЧИСТО" and hb == "НАРУШЕНИЕ" else
                        "other_mismatch"
                    ),
                })

        pct = round(100.0 * agree / comparable, 1) if comparable else None
        prod_auto = None
        # labor productivity among decisions: not escalated / not out-of-scope proxy
        auto_n = sum(1 for a in agents.values() if agent_bucket(a["itog"]) in {"ЧИСТО", "НАРУШЕНИЕ"})
        prod_auto = round(100.0 * auto_n / len(agents), 1) if agents else None

        report["days"][day] = {
            "agent_decisions": len(agents),
            "greta_orders": len(hmap),
            "human_labeled": labeled,
            "comparable_auto": comparable,
            "agree": agree,
            "disagree": comparable - agree,
            "agreement_pct": pct,
            "false_positive": fp,
            "missed_violation": fn,
            "agent_escalated_with_human_label": escalated_ok,
            "human_pending": day_stats["human_pending"],
            "stale_ingest_vs_live": stale_vs_live,
            "productivity_auto_pct": prod_auto,
            "matrix": {f"{a}->{h}": n for (a, h), n in matrix.items()},
            "agent_itog_top": dict(by_agent_itog.most_common(12)),
            "human_breach_dist": dict(Counter((r.get("breach_state") or "null") for r in humans).most_common()),
        }
        all_comp.append((day, comparable, agree, fp, fn, labeled))

    # totals
    tot_c = sum(x[1] for x in all_comp)
    tot_a = sum(x[2] for x in all_comp)
    tot_fp = sum(x[3] for x in all_comp)
    tot_fn = sum(x[4] for x in all_comp)
    tot_lab = sum(x[5] for x in all_comp)
    report["totals"] = {
        "days": len(report["days"]),
        "human_labeled": tot_lab,
        "comparable_auto": tot_c,
        "agree": tot_a,
        "agreement_pct": round(100.0 * tot_a / tot_c, 1) if tot_c else None,
        "false_positive": tot_fp,
        "missed_violation": tot_fn,
        "mismatches_sampled": len(mismatch_rows),
    }

    # mismatch class breakdown
    cls = Counter()
    by_itog = Counter()
    by_note = Counter()
    by_checklist = Counter()
    by_state = Counter()
    fp_photo = 0
    fp_graph = 0
    for m in mismatch_rows:
        cls[m["class"]] += 1
        by_itog[m["agent_itog"]] += 1
        by_note[m["note_class"]] += 1
        by_checklist[m["checklist"] or "none"] += 1
        by_state[str(m["state"] or "?")] += 1
        if m["class"] == "false_positive":
            if "фото" in (m["agent_itog"] or ""):
                fp_photo += 1
            elif "график" in (m["agent_itog"] or ""):
                fp_graph += 1

    report["mismatch_classes"] = {
        "by_class": dict(cls),
        "by_agent_itog": dict(by_itog.most_common(20)),
        "by_human_note_class": dict(by_note.most_common()),
        "by_checklist": dict(by_checklist.most_common()),
        "by_state": dict(by_state.most_common()),
        "false_positive_photo": fp_photo,
        "false_positive_schedule": fp_graph,
    }

    # Top mismatch examples (cap)
    fp_ex = [m for m in mismatch_rows if m["class"] == "false_positive"][:40]
    fn_ex = [m for m in mismatch_rows if m["class"] == "missed_violation"][:40]
    report["examples"] = {"false_positive": fp_ex, "missed_violation": fn_ex}

    # Improvement signals (heuristic)
    signals = []
    if tot_c and tot_fp / tot_c > 0.15:
        signals.append({
            "id": "fp_high",
            "severity": "critical",
            "title": "Много ложных нарушений (агент НАРУШЕНИЕ, человек ЧИСТО)",
            "evidence": f"FP={tot_fp}/{tot_c} ({round(100*tot_fp/tot_c,1)}%)",
            "action": "Ввести quality-gate: спорные фото-кейсы (чеклист 2 / слабые ответы) → К ЧЕЛОВЕКУ вместо авто-НАРУШЕНИЕ",
        })
    if fp_photo and fp_photo >= fp_graph:
        signals.append({
            "id": "photo_fp",
            "severity": "high",
            "title": "Ложные срабатывания чаще по фото, чем по графику",
            "evidence": f"FP фото={fp_photo}, FP график={fp_graph}",
            "action": "Смягчить photo_verdict / soften_o3; не считать нарушение при неоднозначных ДО/ПОСЛЕ; A/B на gpt-4.1 для чеклиста 2",
        })
    if by_checklist.get("2", 0) >= max(by_checklist.values(), default=0) * 0.4 and by_checklist:
        signals.append({
            "id": "checklist_2",
            "severity": "high",
            "title": "Чеклист невывоза (2) доминирует в расхождениях",
            "evidence": f"mismatches by checklist: {dict(by_checklist)}",
            "action": "Отдельный prompt/порог для невывоза: требовать более жёсткое подтверждение нарушения",
        })
    if tot_fn == 0 and tot_fp > 0:
        signals.append({
            "id": "safe_bias",
            "severity": "medium",
            "title": "Агент смещён в сторону «нарушение» (FN≈0)",
            "evidence": f"FN={tot_fn}, FP={tot_fp}",
            "action": "Можно агрессивнее эскалировать сомнения человеку — пропущенных нарушений почти нет",
        })
    if any(d["stale_ingest_vs_live"] > 50 for d in report["days"].values()):
        signals.append({
            "id": "stale_human",
            "severity": "medium",
            "title": "Метки человека в БД агента устарели относительно живой Греты",
            "evidence": {d: v["stale_ingest_vs_live"] for d, v in report["days"].items() if v["stale_ingest_vs_live"]},
            "action": "Периодически рефрешить human_breach_state с Греты для дашборда agreement",
        })
    # labeled coverage
    for d, v in report["days"].items():
        cov = round(100.0 * v["human_labeled"] / v["agent_decisions"], 1) if v["agent_decisions"] else 0
        v["human_label_coverage_pct"] = cov
    low_cov = {d: v["human_label_coverage_pct"] for d, v in report["days"].items() if v["human_label_coverage_pct"] < 15}
    if low_cov:
        signals.append({
            "id": "low_human_coverage",
            "severity": "medium",
            "title": "По части дней человек разметил мало заявок",
            "evidence": low_cov,
            "action": "Считать agreement только на размеченных; для 95% цели нужен больший объём human labels на ЧИСТО/done",
        })

    report["improvement_signals"] = signals

    # Scenario: if send all FP photo to human
    gate_saved = fp_photo  # rough
    if tot_c:
        report["gate_scenario"] = {
            "description": "Если все FP по фото отправить К ЧЕЛОВЕКУ (идеальный gate)",
            "comparable_after": tot_c - gate_saved,
            "agree_after": tot_a,
            "agreement_pct_after": round(100.0 * tot_a / (tot_c - gate_saved), 1) if tot_c > gate_saved else None,
            "note": "Верхняя оценка: предполагает, что все photo-FP можно распознать gate'ом",
        }

import pathlib
path = pathlib.Path("/tmp/agent1_human_review.json")
path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
print("WROTE", path, "bytes", path.stat().st_size)
print("TOTALS", json.dumps(report["totals"], ensure_ascii=False))
print("SIGNALS", len(report["improvement_signals"]))
for d, v in report["days"].items():
    print(f"{d}: labeled={v['human_labeled']} comparable={v['comparable_auto']} agree={v['agreement_pct']}% FP={v['false_positive']} FN={v['missed_violation']} stale={v['stale_ingest_vs_live']}")
PY

echo "DONE $OUT_JSON"
ls -la /tmp/agent1_human_review.json /tmp/human_labels_live.json
