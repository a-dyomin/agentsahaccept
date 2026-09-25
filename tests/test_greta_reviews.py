"""Focused unit tests for Greta's read-only review API serializers."""
from __future__ import annotations

import sys
from datetime import date, datetime, timezone
from pathlib import Path

import pytest
from fastapi import HTTPException

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "agent1" / "app"))

from greta_reviews import (  # noqa: E402
    detail_review,
    haversine_m,
    parse_day,
    require_read_token,
    short_review,
)


def test_read_token_auth_statuses_do_not_leak_secret():
    with pytest.raises(HTTPException) as missing:
        require_read_token(None, "top-secret")
    assert missing.value.status_code == 401
    assert "top-secret" not in str(missing.value.detail)

    with pytest.raises(HTTPException) as wrong:
        require_read_token("wrong", "top-secret")
    assert wrong.value.status_code == 403
    assert "top-secret" not in str(wrong.value.detail)

    require_read_token("top-secret", "top-secret")


def test_day_validation():
    assert parse_day("2026-09-25") == "2026-09-25"
    with pytest.raises(HTTPException) as invalid:
        parse_day("25.09.2026")
    assert invalid.value.status_code == 422


def test_short_review_falls_back_to_runtime_version():
    row = {
        "order_id": 17,
        "day": date(2026, 9, 25),
        "itog": "ЧИСТО",
        "za_chto": "",
        "pometki": None,
        "agent_version": None,
        "created_at": datetime(2026, 9, 25, 8, 0, tzinfo=timezone.utc),
    }
    item = short_review(row, "runtime-version")
    assert item["day"] == "2026-09-25"
    assert item["verdict"] == "ЧИСТО"
    assert item["agent_version"] == "runtime-version"
    assert item["decided_at"] == "2026-09-25T08:00:00+00:00"


def test_detail_includes_math_questions_and_photo_distance():
    row = {
        "order_id": 17,
        "day": date(2026, 9, 25),
        "itog": "НАРУШЕНИЕ (фото)",
        "za_chto": "фото:А4",
        "pometki": "остаток",
        "checklist": "1а",
        "stage1": {"ГЕО_МИН_М": 215.5, "ТРЕК_М": None},
        "stage2": {
            "answers": {"О1": 1, "А4": 1},
            "answers_model": {"О1": "1", "А4": {"answer": 1}},
            "answers_why": {"О1": "кадры видны", "А4": "есть отходы"},
        },
        "agent_version": "v2",
        "created_at": datetime(2026, 9, 25, 8, 0, tzinfo=timezone.utc),
    }
    photos = [
        {
            "photo_id": 99,
            "filename": "JPEG_20260925_121314.jpg",
            "time": datetime(2020, 1, 1, tzinfo=timezone.utc),
            "lat": 56.8500,
            "lon": 53.2000,
            "site_lat": 56.8501,
            "site_lon": 53.2001,
        }
    ]
    detail = detail_review(
        row,
        photos,
        "fallback",
        {
            "PHOTO_RADIUS_M": "250",
            "TRACK_RADIUS_M": "200",
            "NO_PICKUP_TRACK_RADIUS_M": "300",
            "PHOTO_NEAR_ARRIVAL_M": "100",
            "TIME_TOLERANCE_MIN": "7",
            "NO_PICKUP_TIME_TOLERANCE_MIN": "5",
            "TRACK_SEARCH_WINDOW_MIN": "30",
        },
    )

    assert detail["math"]["values"] == row["stage1"]
    assert detail["math"]["thresholds"]["photo_radius_m"] == 250
    assert detail["checklist"]["id"] == "1а"
    assert len(detail["checklist"]["items"]) == 10
    a4 = next(item for item in detail["checklist"]["items"] if item["code"] == "А4")
    assert a4 == {
        "code": "А4",
        "question": "Остались ли отходы в баках на самых поздних снимках?",
        "answer": 1,
        "raw_answer": {"answer": 1},
        "why": "есть отходы",
    }
    assert detail["photos"][0]["shot_time"] == "2026-09-25T12:13:14"
    assert detail["photos"][0]["distance_to_site_m"] == pytest.approx(12.8, abs=0.5)


def test_null_photo_data_is_preserved_gracefully():
    detail = detail_review(
        {
            "order_id": 1,
            "day": "2026-09-25",
            "itog": "К ЧЕЛОВЕКУ",
            "stage1": None,
            "stage2": None,
            "created_at": None,
        },
        [{"photo_id": 2, "filename": None, "time": None, "lat": None, "lon": None}],
        "fallback",
        {},
    )
    assert detail["checklist"] == {"id": None, "items": []}
    assert detail["photos"][0]["shot_time"] is None
    assert detail["photos"][0]["distance_to_site_m"] is None


def test_haversine_rejects_missing_coordinates():
    assert haversine_m(None, 53.2, 56.8, 53.2) is None
