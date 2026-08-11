"""Agent1 control plane: shadow ingest + Stage1 queue + status bar."""
from __future__ import annotations

import json
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from fastapi import BackgroundTasks, FastAPI, HTTPException
from fastapi.responses import FileResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from db import db, fetch_all, fetch_one, init_db
from schema_v2 import SCHEMA_V2
from stage1_shadow import compare_human

BASE = Path(__import__("os").environ.get("AGENT1_HOME", Path(__file__).resolve().parent.parent))
DASH = BASE / "dashboard"
DASH.mkdir(parents=True, exist_ok=True)

_lock = threading.Lock()


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def set_state(state: str, conn=None) -> None:
    sql = (
        "INSERT INTO meta(key,value) VALUES (%s,%s) "
        "ON CONFLICT(key) DO UPDATE SET value=EXCLUDED.value"
    )
    if conn is not None:
        conn.execute(sql, ("agent_state", state))
        return
    with db() as c:
        c.execute(sql, ("agent_state", state))


def get_state() -> str:
    with db() as conn:
        row = fetch_one(conn, "SELECT value FROM meta WHERE key=%s", ("agent_state",))
        return row["value"] if row else "idle"


def log_event(level: str, message: str, conn=None) -> None:
    row = (utc_now(), level, message)
    if conn is not None:
        conn.execute("INSERT INTO events(ts, level, message) VALUES (%s,%s,%s)", row)
        return
    with db() as c:
        c.execute("INSERT INTO events(ts, level, message) VALUES (%s,%s,%s)", row)


class CreateRunRequest(BaseModel):
    day: str = "2026-07-12"
    orders: list[dict[str, Any]] = Field(default_factory=list)
    note: str = ""


class JobResultIn(BaseModel):
    agent_verdict: str
    agent_detail: dict[str, Any] = Field(default_factory=dict)
    human_verdict: str | None = None
    error: str | None = None


class IngestDayRequest(BaseModel):
    day: str
    enqueue: bool = True


app = FastAPI(title="Agent1 Accept Shadow", version="0.3.0")


@app.on_event("startup")
def _startup() -> None:
    init_db()
    with db() as conn:
        conn.execute(SCHEMA_V2)
    log_event("info", "control plane started (postgres + schema v2)")


def _ser_rows(rows: list[dict]) -> list[dict]:
    out = []
    for r in rows:
        item = dict(r)
        for k, v in list(item.items()):
            if hasattr(v, "isoformat"):
                item[k] = v.isoformat()
        out.append(item)
    return out


@app.get("/api/health")
def health() -> dict[str, Any]:
    with db() as conn:
        conn.execute("SELECT 1")
    return {
        "ok": True,
        "ts": utc_now().isoformat(),
        "service": "agent1",
        "db": "postgres",
        "mode": "shadow",
    }


@app.get("/api/s3/smoke")
def s3_smoke() -> dict[str, Any]:
    """Verify Selectel S3 credentials from env (does not download photos)."""
    try:
        from s3_photos import smoke_s3, s3_configured

        if not s3_configured():
            # still allow public-URL-only smoke
            return smoke_s3()
        return smoke_s3()
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=502, detail=str(exc)[:800]) from exc


@app.get("/api/accept/day/{day}")
def accept_day(day: str) -> dict[str, Any]:
    """Acceptance test vs TZ gold numbers. Gold day is 2026-07-12 only (errors doc §5):
    for other days numbers are shown as reference and never marked failed."""
    from accept_test import GOLD_DAY, checklist_breakdown, compare_counts

    with db() as conn:
        snap = fetch_one(
            conn,
            "SELECT day, status, counts, exported_at, error FROM ingest_snapshots WHERE day=%s::date",
            (day,),
        )
        orders = fetch_all(
            conn,
            "SELECT state, waste_type_name, site_stype, photo_count FROM orders_day WHERE day=%s::date",
            (day,),
        )
    if not snap:
        raise HTTPException(status_code=404, detail=f"no ingest for {day}")
    counts = snap.get("counts") or {}
    if isinstance(counts, str):
        import json

        counts = json.loads(counts)
    count_check = compare_counts(counts)
    cl_check = checklist_breakdown([dict(o) for o in orders])
    is_gold = day == GOLD_DAY
    return {
        "day": day,
        "gold_day": GOLD_DAY,
        "comparable": is_gold,
        "exported_at": snap.get("exported_at").isoformat()
        if hasattr(snap.get("exported_at"), "isoformat")
        else snap.get("exported_at"),
        "counts": counts,
        "count_check": count_check,
        "checklist_check": cl_check,
        # only the gold day may fail; other days are reference-only
        "ok": bool(count_check["ok"] and cl_check["ok"]) if is_gold else True,
        "note": None if is_gold else f"контрольные числа относятся к {GOLD_DAY}; для {day} — справочно",
    }


@app.get("/api/status")
def status(day: str | None = None, date_from: str | None = None, date_to: str | None = None) -> dict[str, Any]:
    """Status bar. Optional day=YYYY-MM-DD or date_from/date_to filter dashboards."""
    d_from, d_to = _resolve_range(day, date_from, date_to)
    with db() as conn:
        jobs = fetch_all(conn, "SELECT status, COUNT(*) AS n FROM jobs GROUP BY status")
        by_status = {r["status"]: int(r["n"]) for r in jobs}
        errors = fetch_one(conn, "SELECT COUNT(*) AS n FROM jobs WHERE status='error'")["n"]
        active_run = fetch_one(
            conn,
            "SELECT * FROM runs WHERE status IN ('queued','running') "
            "ORDER BY created_at DESC LIMIT 1",
        )
        recent = fetch_all(
            conn, "SELECT ts, level, message FROM events ORDER BY id DESC LIMIT 15"
        )

        range_sql = ""
        range_args: list[Any] = []
        if d_from and d_to:
            range_sql = " WHERE day >= %s::date AND day <= %s::date"
            range_args = [d_from, d_to]

        decisions_n = fetch_one(
            conn, f"SELECT COUNT(*) AS n FROM agent_decisions{range_sql}", tuple(range_args)
        )["n"]
        cmp_total = fetch_one(
            conn, f"SELECT COUNT(*) AS n FROM comparisons{range_sql}", tuple(range_args)
        )["n"]
        cmp_matched = fetch_one(
            conn,
            f"SELECT COUNT(*) AS n FROM comparisons{range_sql}{' AND' if range_sql else ' WHERE'} match_flag=1",
            tuple(range_args),
        )["n"]
        cmp_pending = fetch_one(
            conn,
            f"SELECT COUNT(*) AS n FROM comparisons{range_sql}{' AND' if range_sql else ' WHERE'} match_flag IS NULL",
            tuple(range_args),
        )["n"]

        if d_from and d_to:
            last_ingest = fetch_one(
                conn,
                "SELECT day, status, counts, exported_at, error FROM ingest_snapshots "
                "WHERE day >= %s::date AND day <= %s::date ORDER BY day DESC LIMIT 1",
                (d_from, d_to),
            )
            itog_dist = fetch_all(
                conn,
                "SELECT itog, COUNT(*) AS n FROM agent_decisions "
                "WHERE day >= %s::date AND day <= %s::date GROUP BY itog ORDER BY n DESC",
                (d_from, d_to),
            )
            diffs = fetch_all(
                conn,
                "SELECT order_id, day, agent_itog, human_breach_state, diff_reason "
                "FROM comparisons WHERE match_flag=0 AND day >= %s::date AND day <= %s::date "
                "ORDER BY created_at DESC LIMIT 8",
                (d_from, d_to),
            )
            last_result = fetch_all(
                conn,
                "SELECT ad.order_id, ad.itog AS agent_verdict, c.human_breach_state AS human_verdict, "
                "c.match_flag, ad.za_chto, ad.pometki, ad.created_at, "
                "o.site_address, o.provider_name "
                "FROM agent_decisions ad "
                "LEFT JOIN comparisons c ON c.day=ad.day AND c.order_id=ad.order_id "
                "LEFT JOIN orders_day o ON o.day=ad.day AND o.order_id=ad.order_id "
                "WHERE ad.day >= %s::date AND ad.day <= %s::date "
                "ORDER BY ad.created_at DESC LIMIT 10",
                (d_from, d_to),
            )
            costs = fetch_one(
                conn,
                "SELECT COALESCE(SUM(prompt_tokens),0) AS prompt_tokens, "
                "COALESCE(SUM(completion_tokens),0) AS completion_tokens, "
                "COALESCE(SUM(total_tokens),0) AS total_tokens, "
                "COALESCE(SUM(cost_usd),0) AS cost_usd, "
                "COUNT(*) AS vision_calls "
                "FROM vision_usage WHERE day >= %s::date AND day <= %s::date",
                (d_from, d_to),
            )
            costs_by_day = fetch_all(
                conn,
                "SELECT day, COUNT(*) AS vision_calls, "
                "COALESCE(SUM(total_tokens),0) AS total_tokens, "
                "COALESCE(SUM(cost_usd),0) AS cost_usd "
                "FROM vision_usage WHERE day >= %s::date AND day <= %s::date "
                "GROUP BY day ORDER BY day",
                (d_from, d_to),
            )
        else:
            last_ingest = fetch_one(
                conn,
                "SELECT day, status, counts, exported_at, error FROM ingest_snapshots "
                "ORDER BY created_at DESC LIMIT 1",
            )
            itog_dist = fetch_all(
                conn,
                "SELECT itog, COUNT(*) AS n FROM agent_decisions GROUP BY itog ORDER BY n DESC",
            )
            diffs = fetch_all(
                conn,
                "SELECT order_id, day, agent_itog, human_breach_state, diff_reason "
                "FROM comparisons WHERE match_flag=0 ORDER BY created_at DESC LIMIT 8",
            )
            last_result = fetch_all(
                conn,
                "SELECT ad.order_id, ad.itog AS agent_verdict, c.human_breach_state AS human_verdict, "
                "c.match_flag, ad.za_chto, ad.pometki, ad.created_at, "
                "o.site_address, o.provider_name "
                "FROM agent_decisions ad "
                "LEFT JOIN comparisons c ON c.day=ad.day AND c.order_id=ad.order_id "
                "LEFT JOIN orders_day o ON o.day=ad.day AND o.order_id=ad.order_id "
                "ORDER BY ad.created_at DESC LIMIT 10",
            )
            costs = fetch_one(
                conn,
                "SELECT COALESCE(SUM(prompt_tokens),0) AS prompt_tokens, "
                "COALESCE(SUM(completion_tokens),0) AS completion_tokens, "
                "COALESCE(SUM(total_tokens),0) AS total_tokens, "
                "COALESCE(SUM(cost_usd),0) AS cost_usd, "
                "COUNT(*) AS vision_calls FROM vision_usage",
            )
            costs_by_day = fetch_all(
                conn,
                "SELECT day, COUNT(*) AS vision_calls, "
                "COALESCE(SUM(total_tokens),0) AS total_tokens, "
                "COALESCE(SUM(cost_usd),0) AS cost_usd "
                "FROM vision_usage GROUP BY day ORDER BY day DESC LIMIT 14",
            )

        # Архив дней всегда полный: не сужаем available_days фильтром day/date_from/date_to.
        days_list = fetch_all(
            conn, "SELECT day FROM ingest_snapshots ORDER BY day DESC LIMIT 60"
        )

    compared = int(cmp_total) - int(cmp_pending) if cmp_total else 0
    agreement = (
        round(100.0 * int(cmp_matched) / compared, 1) if compared else None
    )

    # «НАРУШЕНИЕ (фото)» смешивает провал ГЕО (Этап 1) и претензии к самим кадрам.
    # Для отчётности разводим: za_chto с «фото:» — содержание, без него — только ГЕО/график.
    with db() as conn:
        if d_from and d_to:
            photo_split = fetch_one(
                conn,
                "SELECT COUNT(*) FILTER (WHERE za_chto LIKE '%%фото:%%')::int AS content, "
                "COUNT(*) FILTER (WHERE za_chto NOT LIKE '%%фото:%%')::int AS geo_only "
                "FROM agent_decisions WHERE itog='НАРУШЕНИЕ (фото)' "
                "AND day >= %s::date AND day <= %s::date",
                (d_from, d_to),
            )
        else:
            photo_split = fetch_one(
                conn,
                "SELECT COUNT(*) FILTER (WHERE za_chto LIKE '%%фото:%%')::int AS content, "
                "COUNT(*) FILTER (WHERE za_chto NOT LIKE '%%фото:%%')::int AS geo_only "
                "FROM agent_decisions WHERE itog='НАРУШЕНИЕ (фото)'",
            )

    # Coverage / special buckets from agent_decisions
    not_in_work = 0
    failed_shift = 0
    not_checked = 0
    auto_checked = 0
    sent_to_human = 0
    for row in itog_dist or []:
        it = str(row.get("itog") or "")
        n = int(row.get("n") or 0)
        if it == "НЕ ВЗЯТА В РАБОТУ":
            not_in_work = n
        elif it == "СМЕНА НЕ ВЫШЛА":
            failed_shift = n
        elif it == "НЕ ПРОВЕРЯЕТСЯ":
            not_checked = n
        elif it == "К ЧЕЛОВЕКУ":
            sent_to_human = n
        elif it == "ЧИСТО" or it.startswith("НАРУШЕНИЕ"):
            auto_checked += n

    # «Производительность труда»: доля акцептов, по которым агент сам вынес
    # конечное решение. Служебные/out-of-scope статусы в знаменатель не входят.
    labor_scope = auto_checked + sent_to_human
    labor_productivity = (
        round(100.0 * auto_checked / labor_scope, 1) if labor_scope else None
    )

    active = None
    if active_run:
        active = dict(active_run)
        for k, v in list(active.items()):
            if hasattr(v, "isoformat"):
                active[k] = v.isoformat()

    ingest = None
    if last_ingest:
        ingest = dict(last_ingest)
        if hasattr(ingest.get("day"), "isoformat"):
            ingest["day"] = ingest["day"].isoformat()
        if hasattr(ingest.get("exported_at"), "isoformat"):
            ingest["exported_at"] = ingest["exported_at"].isoformat()

    cost_block = {
        "prompt_tokens": int((costs or {}).get("prompt_tokens") or 0),
        "completion_tokens": int((costs or {}).get("completion_tokens") or 0),
        "total_tokens": int((costs or {}).get("total_tokens") or 0),
        "cost_usd": round(float((costs or {}).get("cost_usd") or 0), 4),
        "vision_calls": int((costs or {}).get("vision_calls") or 0),
        "by_day": _ser_rows(costs_by_day or []),
    }

    return {
        "ts": utc_now().isoformat(),
        "agent_state": get_state(),
        "mode": "shadow",
        "filter": {"day": day, "date_from": d_from, "date_to": d_to},
        "available_days": [
            (r["day"].isoformat() if hasattr(r["day"], "isoformat") else str(r["day"]))
            for r in (days_list or [])
        ],
        "active_run": active,
        "last_ingest": ingest,
        "counts": {
            "queued": by_status.get("queued", 0),
            "in_progress": by_status.get("leased", 0),
            "processed": int(decisions_n) if (d_from and d_to) else by_status.get("done", 0),
            "errors": int(errors),
            "results": int(decisions_n),
            "compared_with_human": compared,
            "agreed_with_human": int(cmp_matched),
            "human_pending": int(cmp_pending),
            "not_in_work": not_in_work,
            "failed_shift": failed_shift,
            "not_checked": not_checked,
            "photo_by_content": int((photo_split or {}).get("content") or 0),
            "photo_by_geo_only": int((photo_split or {}).get("geo_only") or 0),
            "auto_checked": auto_checked,
            "sent_to_human": sent_to_human,
        },
        "agreement_pct": agreement,
        "labor_productivity_pct": labor_productivity,
        "labor_productivity_scope": (
            "авторешения / (авторешения + К ЧЕЛОВЕКУ); "
            "служебные и out-of-scope статусы исключены"
        ),
        "agreement_scope": (
            "только заявки с human-акцептом (match_flag не NULL); "
            "done без акцепта не входят — KPI в основном по невывозам"
        ),
        "costs": cost_block,
        "itog_distribution": _ser_rows(itog_dist),
        "recent_diffs": _ser_rows(diffs),
        "db": "postgres",
        "recent_events": _ser_rows(recent),
        "recent_results": _ser_rows(last_result),
    }


def _resolve_range(
    day: str | None, date_from: str | None, date_to: str | None
) -> tuple[str | None, str | None]:
    if day:
        return day, day
    if date_from or date_to:
        return date_from or date_to, date_to or date_from
    return None, None


def _run_ingest_job(day: str, enqueue: bool) -> None:
    from ingest import ingest_and_enqueue, persist_export, pull_day_json, ensure_schema, enqueue_stage1

    try:
        ensure_schema()
        set_state("ingesting")
        log_event("info", f"ingest started day={day}")
        payload = pull_day_json(day)
        stats = persist_export(payload)
        log_event("info", f"ingest done day={day} orders={stats['orders']} photos={stats['photos']}")
        if enqueue:
            run = enqueue_stage1(day)
            set_state("processing")
            log_event("info", f"stage1 enqueued run={run['run_id']} jobs={run['jobs']}")
        else:
            set_state("idle")
    except Exception as exc:  # noqa: BLE001
        set_state("degraded")
        log_event("error", f"ingest failed day={day}: {exc}")


@app.post("/api/ingest/day/{day}")
def ingest_day(day: str, background_tasks: BackgroundTasks, enqueue: bool = True) -> dict[str, Any]:
    """Pull Greta day via SSH export and optionally enqueue Stage1 jobs (async)."""
    background_tasks.add_task(_run_ingest_job, day, enqueue)
    return {"accepted": True, "day": day, "enqueue": enqueue, "status": "started"}


@app.post("/api/ingest/day/{day}/sync")
def ingest_day_sync(day: str, enqueue: bool = True) -> dict[str, Any]:
    """Synchronous ingest (for first bring-up / debugging)."""
    from ingest import persist_export, pull_day_json, ensure_schema, enqueue_stage1

    ensure_schema()
    set_state("ingesting")
    payload = pull_day_json(day)
    stats = persist_export(payload)
    result: dict[str, Any] = {"ingest": stats}
    if enqueue:
        result["run"] = enqueue_stage1(day)
        set_state("processing")
    else:
        set_state("idle")
    return result


@app.post("/api/enrich/schedules/{day}")
def enrich_schedules(day: str, background_tasks: BackgroundTasks) -> dict[str, Any]:
    """Light pull of Greta Schedule (ID смены) + photo.schedule_id — no Wialon."""

    def _job() -> None:
        from ingest import enrich_schedules_day

        try:
            stats = enrich_schedules_day(day)
            log_event("info", f"schedules enrich day={day} {stats}")
        except Exception as exc:  # noqa: BLE001
            log_event("error", f"schedules enrich failed day={day}: {exc}")

    background_tasks.add_task(_job)
    return {"accepted": True, "day": day, "kind": "schedules_enrich", "status": "started"}


@app.post("/api/enrich/schedules/{day}/sync")
def enrich_schedules_sync(day: str) -> dict[str, Any]:
    from ingest import enrich_schedules_day

    return enrich_schedules_day(day)


@app.get("/api/schedules")
def list_schedules(day: str, limit: int = 200) -> dict[str, Any]:
    with db() as conn:
        rows = fetch_all(
            conn,
            "SELECT * FROM schedules_day WHERE day=%s::date ORDER BY schedule_id LIMIT %s",
            (day, limit),
        )
        n = fetch_one(
            conn, "SELECT COUNT(*) AS n FROM schedules_day WHERE day=%s::date", (day,)
        )["n"]
    return {"day": day, "total": int(n), "items": _ser_rows(rows)}


@app.post("/api/runs")
def create_run(body: CreateRunRequest) -> dict[str, Any]:
    if not body.orders:
        raise HTTPException(400, "orders list is empty")
    run_id = str(uuid.uuid4())
    now = utc_now()
    with _lock, db() as conn:
        conn.execute(
            "INSERT INTO runs(id, day, status, created_at, note) VALUES (%s,%s,%s,%s,%s)",
            (run_id, body.day, "queued", now, body.note),
        )
        for item in body.orders:
            oid = int(item["order_id"])
            job_id = str(uuid.uuid4())
            conn.execute(
                "INSERT INTO jobs(id, run_id, order_id, kind, payload, status, created_at) "
                "VALUES (%s,%s,%s,%s,%s::jsonb,%s,%s)",
                (
                    job_id,
                    run_id,
                    oid,
                    item.get("kind", "stage1_shadow"),
                    json.dumps(item, ensure_ascii=False),
                    "queued",
                    now,
                ),
            )
        set_state("running", conn)
        conn.execute(
            "UPDATE runs SET status='running', started_at=%s WHERE id=%s",
            (now, run_id),
        )
        log_event("info", f"run {run_id} created with {len(body.orders)} jobs", conn)
    return {"run_id": run_id, "jobs": len(body.orders)}


@app.get("/api/jobs/next")
def next_job(worker_id: str = "worker-1") -> dict[str, Any]:
    now = utc_now()
    with _lock, db() as conn:
        row = fetch_one(
            conn,
            "SELECT * FROM jobs WHERE status='queued' ORDER BY created_at LIMIT 1 "
            "FOR UPDATE SKIP LOCKED",
        )
        if not row:
            open_jobs = fetch_one(
                conn,
                "SELECT COUNT(*) AS n FROM jobs WHERE status IN ('queued','leased')",
            )["n"]
            if open_jobs == 0:
                conn.execute(
                    "UPDATE runs SET status='done', finished_at=%s WHERE status='running'",
                    (now,),
                )
                # don't clobber ingesting/degraded while Greta export is still running
                cur = fetch_one(conn, "SELECT value FROM meta WHERE key=%s", ("agent_state",))
                if (cur or {}).get("value") in (None, "processing", "running", "idle"):
                    set_state("idle", conn)
            return {"job": None}
        conn.execute(
            "UPDATE jobs SET status='leased', leased_at=%s WHERE id=%s",
            (now, row["id"]),
        )
        set_state("processing", conn)
        payload = row["payload"]
        if isinstance(payload, str):
            payload = json.loads(payload)
        return {
            "job": {
                "id": row["id"],
                "run_id": row["run_id"],
                "order_id": row["order_id"],
                "kind": row["kind"],
                "payload": payload,
                "worker_id": worker_id,
            }
        }


@app.post("/api/jobs/{job_id}/result")
def post_result(job_id: str, body: JobResultIn) -> dict[str, Any]:
    now = utc_now()
    with _lock, db() as conn:
        job = fetch_one(conn, "SELECT * FROM jobs WHERE id=%s", (job_id,))
        if not job:
            raise HTTPException(404, "job not found")
        if body.error:
            conn.execute(
                "UPDATE jobs SET status='error', finished_at=%s, error=%s WHERE id=%s",
                (now, body.error, job_id),
            )
            log_event("error", f"job {job_id} order={job['order_id']}: {body.error}", conn)
            return {"ok": False}

        detail = body.agent_detail or {}
        day = detail.get("day") or None
        if not day:
            # try payload
            raw_payload = job["payload"]
            if isinstance(raw_payload, str):
                raw_payload = json.loads(raw_payload)
            day = (raw_payload or {}).get("day")
        if not day:
            run = fetch_one(conn, "SELECT day FROM runs WHERE id=%s", (job["run_id"],))
            day = run["day"] if run else None

        human = body.human_verdict or detail.get("human_breach_state")
        match, diff_reason = compare_human(body.agent_verdict, human)

        rid = str(uuid.uuid4())
        conn.execute(
            "INSERT INTO results(id, run_id, job_id, order_id, agent_verdict, agent_detail, "
            "human_verdict, match_flag, created_at) VALUES (%s,%s,%s,%s,%s,%s::jsonb,%s,%s,%s)",
            (
                rid,
                job["run_id"],
                job_id,
                job["order_id"],
                body.agent_verdict,
                json.dumps(detail, ensure_ascii=False),
                human,
                match,
                now,
            ),
        )
        conn.execute(
            "UPDATE jobs SET status='done', finished_at=%s, error=NULL WHERE id=%s",
            (now, job_id),
        )

        if day:
            conn.execute(
                """
                INSERT INTO agent_decisions(
                  day, order_id, run_id, itog, za_chto, pometki, checklist, stage1, stage2, created_at
                ) VALUES (
                  %s::date,%s,%s,%s,%s,%s,%s,%s::jsonb,%s::jsonb,%s
                )
                ON CONFLICT (day, order_id) DO UPDATE SET
                  run_id=EXCLUDED.run_id,
                  itog=EXCLUDED.itog,
                  za_chto=EXCLUDED.za_chto,
                  pometki=EXCLUDED.pometki,
                  checklist=EXCLUDED.checklist,
                  stage1=EXCLUDED.stage1,
                  stage2=EXCLUDED.stage2,
                  created_at=EXCLUDED.created_at
                """,
                (
                    str(day),
                    job["order_id"],
                    job["run_id"],
                    detail.get("itog") or body.agent_verdict,
                    detail.get("za_chto"),
                    detail.get("pometki"),
                    detail.get("checklist"),
                    json.dumps(detail.get("stage1") or {}, ensure_ascii=False),
                    json.dumps(detail.get("stage2"), ensure_ascii=False)
                    if detail.get("stage2") is not None
                    else None,
                    now,
                ),
            )
            conn.execute(
                """
                INSERT INTO comparisons(day, order_id, agent_itog, human_breach_state, match_flag, diff_reason, created_at)
                VALUES (%s::date,%s,%s,%s,%s,%s,%s)
                ON CONFLICT (day, order_id) DO UPDATE SET
                  agent_itog=EXCLUDED.agent_itog,
                  human_breach_state=EXCLUDED.human_breach_state,
                  match_flag=EXCLUDED.match_flag,
                  diff_reason=EXCLUDED.diff_reason,
                  created_at=EXCLUDED.created_at
                """,
                (
                    str(day),
                    job["order_id"],
                    body.agent_verdict,
                    human,
                    match,
                    diff_reason,
                    now,
                ),
            )
            s2 = detail.get("stage2") or {}
            usage = (s2.get("usage") or {}) if isinstance(s2, dict) else {}
            if usage and int(usage.get("total_tokens") or 0) > 0:
                conn.execute(
                    """
                    INSERT INTO vision_usage(
                      day, order_id, run_id, model, prompt_tokens, completion_tokens,
                      total_tokens, cost_usd, checklist, created_at
                    ) VALUES (%s::date,%s,%s,%s,%s,%s,%s,%s,%s,%s)
                    """,
                    (
                        str(day),
                        job["order_id"],
                        job["run_id"],
                        s2.get("model"),
                        int(usage.get("prompt_tokens") or 0),
                        int(usage.get("completion_tokens") or 0),
                        int(usage.get("total_tokens") or 0),
                        float(usage.get("cost_usd") or 0),
                        s2.get("checklist"),
                        now,
                    ),
                )

    return {"ok": True, "result_id": rid, "match": match, "diff_reason": diff_reason}


@app.get("/api/results")
def list_results(limit: int = 100) -> dict[str, Any]:
    with db() as conn:
        rows = fetch_all(
            conn, "SELECT * FROM results ORDER BY created_at DESC LIMIT %s", (limit,)
        )
    return {"items": _ser_rows(rows)}


@app.get("/api/compare")
def compare() -> dict[str, Any]:
    with db() as conn:
        rows = fetch_all(
            conn,
            """
            SELECT agent_itog, human_breach_state, match_flag, COUNT(*) AS n
            FROM comparisons
            GROUP BY agent_itog, human_breach_state, match_flag
            ORDER BY n DESC
            """,
        )
        total = fetch_one(
            conn, "SELECT COUNT(*) AS n FROM comparisons WHERE match_flag IS NOT NULL"
        )["n"]
        agreed = fetch_one(
            conn, "SELECT COUNT(*) AS n FROM comparisons WHERE match_flag=1"
        )["n"]
    return {
        "compared": int(total),
        "agreed": int(agreed),
        "agreement_pct": round(100.0 * agreed / total, 1) if total else None,
        "matrix": _ser_rows(rows),
    }


@app.get("/", response_model=None)
def index():
    index_path = DASH / "index.html"
    if index_path.exists():
        return FileResponse(index_path)
    return HTMLResponse("<h1>agent1</h1><p>dashboard missing</p>")


if DASH.exists():
    app.mount("/static", StaticFiles(directory=str(DASH)), name="static")
