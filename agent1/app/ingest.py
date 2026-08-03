"""Ingest a Greta day export JSON into Agent1 Postgres + enqueue Stage1 jobs."""
from __future__ import annotations

import json
import os
import subprocess
import tempfile
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any

from db import db, fetch_one
from schema_v2 import SCHEMA_V2

GRETA_SSH_HOST = os.environ.get("GRETA_SSH_HOST", "greta.akea-ds.ru")
GRETA_SSH_PORT = os.environ.get("GRETA_SSH_PORT", "34023")
GRETA_SSH_USER = os.environ.get("GRETA_SSH_USER", "gretaadmin")
GRETA_SSH_KEY = str(
    Path(
        os.environ.get("GRETA_SSH_KEY", str(Path.home() / ".ssh" / "greta_ro"))
    ).expanduser()
)
GRETA_EXPORT_SCRIPT = os.environ.get(
    "GRETA_EXPORT_SCRIPT",
    "/home/gretaadmin/agent1_export/export_day.rb",
)
GRETA_BACKEND = os.environ.get(
    "GRETA_BACKEND", "/home/gretaadmin/greta-backend/current"
)


def ensure_schema() -> None:
    with db() as conn:
        conn.execute(SCHEMA_V2)


def pull_day_json(day: str, limit: int | None = None) -> dict[str, Any]:
    """SSH to Greta and run rails exporter; return parsed JSON."""
    lim = limit if limit is not None else os.environ.get("GRETA_EXPORT_LIMIT")
    lim_arg = f" {int(lim)}" if lim not in (None, "", "0") else ""
    remote = (
        f"cd {GRETA_BACKEND} && "
        f"export PATH=$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH && "
        f'eval "$(rbenv init -)" && '
        f"RAILS_ENV=production bundle exec rails runner {GRETA_EXPORT_SCRIPT} {day}{lim_arg}"
    )
    cmd = [
        "ssh",
        "-i",
        GRETA_SSH_KEY,
        "-p",
        GRETA_SSH_PORT,
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=30",
        f"{GRETA_SSH_USER}@{GRETA_SSH_HOST}",
        remote,
    ]
    # write to temp file to avoid huge memory spikes in pipe buffering issues
    with tempfile.NamedTemporaryFile(prefix="greta_day_", suffix=".json", delete=False) as tmp:
        tmp_path = Path(tmp.name)
    try:
        with tmp_path.open("wb") as out:
            proc = subprocess.run(
                cmd,
                stdout=out,
                stderr=subprocess.PIPE,
                timeout=60 * 45,
                check=False,
            )
        if proc.returncode != 0:
            err = proc.stderr.decode("utf-8", "replace")[-2000:]
            raise RuntimeError(f"greta export failed rc={proc.returncode}: {err}")
        raw = tmp_path.read_text(encoding="utf-8")
        # rails may print warnings before JSON — find first {
        i = raw.find("{")
        if i < 0:
            raise RuntimeError("no JSON in greta export output")
        return json.loads(raw[i:])
    finally:
        tmp_path.unlink(missing_ok=True)


def persist_export(payload: dict[str, Any]) -> dict[str, Any]:
    day = payload["day"]
    orders = payload.get("orders") or []
    photos = payload.get("photos") or []
    counts = payload.get("counts") or {}
    exported_at = payload.get("exported_at")

    with db() as conn:
        conn.execute(
            """
            INSERT INTO ingest_snapshots(day, exported_at, counts, status)
            VALUES (%s::date, %s::timestamptz, %s::jsonb, 'done')
            ON CONFLICT (day) DO UPDATE SET
              exported_at=EXCLUDED.exported_at,
              counts=EXCLUDED.counts,
              status='done',
              error=NULL
            """,
            (day, exported_at, json.dumps(counts)),
        )
        conn.execute("DELETE FROM orders_day WHERE day=%s::date", (day,))
        conn.execute("DELETE FROM photos_day WHERE day=%s::date", (day,))

        for o in orders:
            conn.execute(
                """
                INSERT INTO orders_day(
                  day, order_id, state, site_id, site_address, site_stype, site_lat, site_lon,
                  schedule_id, vehicle_id, plate, provider_name, waste_type_name, create_type,
                  change_source, transfered, container_count, started_at, finished_at, canceled_at,
                  human_breach_state, human_accept_note, human_regoper_note,
                  has_report, report_success, report_comment, fail_reason,
                  photo_count, geo_flag, geo_min_m, geo_out, geo_no_coord,
                  track_exists, track_flag, track_min_m, arrival_ts, time_flag, time_dev_min, raw
                ) VALUES (
                  %s::date,%s,%s,%s,%s,%s,%s,%s,
                  %s,%s,%s,%s,%s,%s,
                  %s,%s,%s,%s,%s,%s,
                  %s,%s,%s,
                  %s,%s,%s,%s,
                  %s,%s,%s,%s,%s,
                  %s,%s,%s,%s,%s,%s,%s::jsonb
                )
                """,
                (
                    day,
                    o["id"],
                    o.get("state"),
                    o.get("site_id"),
                    o.get("site_address"),
                    str(o.get("site_stype")) if o.get("site_stype") is not None else None,
                    o.get("site_lat"),
                    o.get("site_lon"),
                    o.get("schedule_id"),
                    o.get("vehicle_id"),
                    o.get("plate"),
                    o.get("provider_name"),
                    o.get("waste_type_name"),
                    o.get("create_type"),
                    o.get("change_source"),
                    o.get("transfered"),
                    o.get("container_count"),
                    o.get("started_at"),
                    o.get("finished_at"),
                    o.get("canceled_at"),
                    o.get("human_breach_state"),
                    o.get("human_accept_note"),
                    o.get("human_regoper_note"),
                    o.get("has_report"),
                    o.get("report_success"),
                    o.get("report_comment"),
                    o.get("fail_reason"),
                    o.get("photo_count"),
                    str(o.get("geo_flag")) if o.get("geo_flag") is not None else None,
                    o.get("geo_min_m"),
                    o.get("geo_out"),
                    o.get("geo_no_coord"),
                    o.get("track_exists"),
                    str(o.get("track_flag")) if o.get("track_flag") is not None else None,
                    o.get("track_min_m"),
                    o.get("arrival_ts"),
                    str(o.get("time_flag")) if o.get("time_flag") is not None else None,
                    o.get("time_dev_min"),
                    json.dumps(o, ensure_ascii=False),
                ),
            )
            # human_decisions snapshot
            conn.execute(
                """
                INSERT INTO human_decisions(day, order_id, breach_state, accept_note, regoper_note, synced_at)
                VALUES (%s::date,%s,%s,%s,%s,NOW())
                ON CONFLICT (day, order_id) DO UPDATE SET
                  breach_state=EXCLUDED.breach_state,
                  accept_note=EXCLUDED.accept_note,
                  regoper_note=EXCLUDED.regoper_note,
                  synced_at=NOW()
                """,
                (
                    day,
                    o["id"],
                    o.get("human_breach_state"),
                    o.get("human_accept_note"),
                    o.get("human_regoper_note"),
                ),
            )

        for p in photos:
            conn.execute(
                """
                INSERT INTO photos_day(day, photo_id, order_id, ptype, time, filename, blob_key, photo_url, lon, lat)
                VALUES (%s::date,%s,%s,%s,%s,%s,%s,%s,%s,%s)
                ON CONFLICT (day, photo_id) DO UPDATE SET
                  blob_key=EXCLUDED.blob_key, photo_url=EXCLUDED.photo_url,
                  lon=EXCLUDED.lon, lat=EXCLUDED.lat
                """,
                (
                    day,
                    p["id"],
                    p["order_id"],
                    str(p.get("ptype")) if p.get("ptype") is not None else None,
                    p.get("time"),
                    p.get("filename"),
                    p.get("blob_key"),
                    p.get("photo_url"),
                    p.get("lon"),
                    p.get("lat"),
                ),
            )

    return {"day": day, "orders": len(orders), "photos": len(photos), "counts": counts}


def enqueue_stage1(day: str, note: str = "shadow stage1") -> dict[str, Any]:
    """Create run + jobs from orders_day for Stage1 decision."""
    import uuid
    from datetime import datetime, timezone

    run_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc)
    with db() as conn:
        rows = list(
            conn.execute(
                "SELECT * FROM orders_day WHERE day=%s::date ORDER BY order_id",
                (day,),
            )
        )
        if not rows:
            raise RuntimeError(f"no orders_day for {day}")
        conn.execute(
            "INSERT INTO runs(id, day, status, created_at, note) VALUES (%s,%s,%s,%s,%s)",
            (run_id, day, "running", now, note),
        )
        photos_by_order: dict[int, list[dict]] = {}
        for p in conn.execute(
            "SELECT photo_id, order_id, blob_key, photo_url, ptype, filename FROM photos_day WHERE day=%s::date",
            (day,),
        ):
            photos_by_order.setdefault(int(p["order_id"]), []).append(
                {
                    "photo_id": p["photo_id"],
                    "blob_key": p["blob_key"],
                    "photo_url": p.get("photo_url"),
                    "ptype": p["ptype"],
                    "filename": p["filename"],
                }
            )

        for r in rows:
            oid = int(r["order_id"])
            payload = {
                "kind": "stage1_stage2",
                "day": day,
                "order_id": oid,
                "state": r["state"],
                "schedule_id": r["schedule_id"],
                "photo_count": r["photo_count"] or 0,
                "geo_flag": r["geo_flag"],
                "geo_min_m": r["geo_min_m"],
                "geo_out": r["geo_out"],
                "geo_no_coord": r["geo_no_coord"],
                "track_exists": r["track_exists"],
                "track_flag": r["track_flag"],
                "track_min_m": r["track_min_m"],
                "time_flag": r["time_flag"],
                "time_dev_min": r["time_dev_min"],
                "has_report": r["has_report"],
                "fail_reason": r["fail_reason"],
                "report_comment": r["report_comment"],
                "human_breach_state": r["human_breach_state"],
                "site_stype": r["site_stype"],
                "site_address": r["site_address"],
                "waste_type_name": r["waste_type_name"],
                "change_source": r["change_source"],
                "photos": photos_by_order.get(oid, []),
            }
            job_id = str(uuid.uuid4())
            conn.execute(
                "INSERT INTO jobs(id, run_id, order_id, kind, payload, status, created_at) "
                "VALUES (%s,%s,%s,%s,%s::jsonb,%s,%s)",
                (
                    job_id,
                    run_id,
                    oid,
                    "stage1_stage2",
                    json.dumps(payload, ensure_ascii=False),
                    "queued",
                    now,
                ),
            )
        conn.execute(
            "INSERT INTO meta(key,value) VALUES ('agent_state','running') "
            "ON CONFLICT(key) DO UPDATE SET value=EXCLUDED.value"
        )
        conn.execute(
            "INSERT INTO events(ts, level, message) VALUES (NOW(), 'info', %s)",
            (f"enqueued stage1 run {run_id} day={day} jobs={len(rows)}",),
        )
    return {"run_id": run_id, "jobs": len(rows)}


def ingest_and_enqueue(day: str) -> dict[str, Any]:
    ensure_schema()
    set_state_safe("ingesting")
    try:
        payload = pull_day_json(day)
        stats = persist_export(payload)
        run = enqueue_stage1(day)
        set_state_safe("processing")
        return {"ingest": stats, "run": run}
    except Exception as exc:
        set_state_safe("degraded")
        with db() as conn:
            conn.execute(
                """
                INSERT INTO ingest_snapshots(day, counts, status, error)
                VALUES (%s::date, '{}'::jsonb, 'error', %s)
                ON CONFLICT (day) DO UPDATE SET status='error', error=EXCLUDED.error
                """,
                (day, str(exc)[:2000]),
            )
        raise


def set_state_safe(state: str) -> None:
    with db() as conn:
        conn.execute(
            "INSERT INTO meta(key,value) VALUES ('agent_state',%s) "
            "ON CONFLICT(key) DO UPDATE SET value=EXCLUDED.value",
            (state,),
        )
