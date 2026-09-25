"""Serialization helpers for Greta's read-only Agent1 review UI."""
from __future__ import annotations

import hmac
import json
import math
import os
from datetime import date
from typing import Any, Mapping

from fastapi import HTTPException

from checklist_prompts import question_map
from checklist_verdict import CODES
from photo_meta import shot_datetime_from_filename


def require_read_token(provided: str | None, expected: str | None = None) -> None:
    """Validate Greta's service token without returning or logging either value."""
    if not provided:
        raise HTTPException(status_code=401, detail="service token required")
    configured = expected if expected is not None else os.environ.get("AGENT1_GRETA_READ_TOKEN")
    if not configured:
        raise HTTPException(status_code=503, detail="read API is not configured")
    if not hmac.compare_digest(provided, configured):
        raise HTTPException(status_code=403, detail="service token invalid")


def parse_day(value: str) -> str:
    try:
        return date.fromisoformat(value).isoformat()
    except (TypeError, ValueError) as exc:
        raise HTTPException(status_code=422, detail="day must be YYYY-MM-DD") from exc


def _json_object(value: Any) -> dict[str, Any]:
    if isinstance(value, Mapping):
        return dict(value)
    if isinstance(value, str):
        try:
            decoded = json.loads(value)
            return dict(decoded) if isinstance(decoded, Mapping) else {}
        except (TypeError, ValueError):
            return {}
    return {}


def _iso(value: Any) -> Any:
    return value.isoformat() if hasattr(value, "isoformat") else value


def short_review(row: Mapping[str, Any], fallback_version: str) -> dict[str, Any]:
    return {
        "order_id": row.get("order_id"),
        "day": _iso(row.get("day")),
        "verdict": row.get("itog"),
        "za_chto": row.get("za_chto"),
        "pometki": row.get("pometki"),
        "agent_version": row.get("agent_version") or fallback_version,
        "decided_at": _iso(row.get("created_at")),
    }


def review_thresholds(env: Mapping[str, str] | None = None) -> dict[str, Any]:
    source = env if env is not None else os.environ

    def number(name: str, default: str) -> int | float:
        raw = source.get(name, default)
        value = float(raw)
        return int(value) if value.is_integer() else value

    return {
        "photo_radius_m": number("PHOTO_RADIUS_M", "200"),
        "track_radius_m": number("TRACK_RADIUS_M", "200"),
        "no_pickup_track_radius_m": number("NO_PICKUP_TRACK_RADIUS_M", "300"),
        "photo_near_arrival_m": number("PHOTO_NEAR_ARRIVAL_M", "100"),
        "time_tolerance_min": number("TIME_TOLERANCE_MIN", "7"),
        "no_pickup_time_tolerance_min": number(
            "NO_PICKUP_TIME_TOLERANCE_MIN", "5"
        ),
        "track_search_window_min": number("TRACK_SEARCH_WINDOW_MIN", "30"),
    }


def checklist_rows(checklist: str | None, stage2: Any) -> list[dict[str, Any]]:
    data = _json_object(stage2)
    answers = _json_object(data.get("answers"))
    raw_answers = _json_object(data.get("answers_model"))
    why = _json_object(data.get("answers_why"))
    checklist_id = checklist or data.get("checklist")
    questions = question_map(str(checklist_id or ""))
    return [
        {
            "code": code,
            "question": questions.get(code),
            "answer": answers.get(code),
            "raw_answer": raw_answers.get(code),
            "why": why.get(code),
        }
        for code in CODES.get(str(checklist_id or ""), ())
    ]


def haversine_m(
    lat1: Any, lon1: Any, lat2: Any, lon2: Any
) -> float | None:
    try:
        values = tuple(float(v) for v in (lat1, lon1, lat2, lon2))
    except (TypeError, ValueError):
        return None
    if not all(math.isfinite(v) for v in values):
        return None
    p1, l1, p2, l2 = map(math.radians, values)
    dlat, dlon = p2 - p1, l2 - l1
    a = math.sin(dlat / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dlon / 2) ** 2
    a = min(1.0, max(0.0, a))
    return round(6_371_000 * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a)), 1)


def photo_row(row: Mapping[str, Any]) -> dict[str, Any]:
    filename = row.get("filename")
    filename_time = shot_datetime_from_filename(str(filename or ""))
    db_time = row.get("time")
    return {
        "photo_id": row.get("photo_id"),
        "filename": filename,
        "shot_time": _iso(filename_time or db_time),
        "distance_to_site_m": haversine_m(
            row.get("lat"),
            row.get("lon"),
            row.get("site_lat"),
            row.get("site_lon"),
        ),
    }


def detail_review(
    row: Mapping[str, Any],
    photos: list[Mapping[str, Any]],
    fallback_version: str,
    env: Mapping[str, str] | None = None,
) -> dict[str, Any]:
    result = short_review(row, fallback_version)
    stage1 = _json_object(row.get("stage1"))
    stage2 = _json_object(row.get("stage2"))
    checklist_id = row.get("checklist") or stage2.get("checklist")
    result.update(
        {
            "math": {
                "values": stage1,
                "thresholds": review_thresholds(env),
            },
            "checklist": {
                "id": checklist_id,
                "items": checklist_rows(
                    str(checklist_id) if checklist_id is not None else None,
                    stage2,
                ),
            },
            "photos": [photo_row(photo) for photo in photos],
        }
    )
    return result
