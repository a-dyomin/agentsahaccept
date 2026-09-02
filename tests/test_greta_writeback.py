"""Greta review_accept JSON payload — quoted keys/strings via json.dumps."""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "agent1" / "greta"))

from review_accept_writeback import comment_from_detail, payload_for_verdict  # noqa: E402


def test_payload_json_is_quoted_and_matches_greta_contract():
    body = payload_for_verdict(
        order_id=6162287,
        agent_verdict="ЧИСТО",
        agent_comment="баков на фото: 1",
        agent_version="test_curl",
        decision_id="937d0ba8-918c-4565-9e66-65a9bee988c4",
        decided_at=__import__("datetime").datetime(2026, 8, 28, 6, 5, 55, tzinfo=__import__("datetime").timezone.utc),
    )
    raw = json.dumps(body, ensure_ascii=False)
    parsed = json.loads(raw)
    assert parsed["order_id"] == 6162287
    assert parsed["agent_breach_detected"] is False
    assert parsed["agent_status"] == "decided"
    assert parsed["agent_result_code"] == "clean"
    assert parsed["agent_comment"] == "баков на фото: 1"
    assert parsed["agent_version"] == "test_curl"
    assert parsed["decided_at"] == "2026-08-28T06:05:55Z"
    assert parsed["decision_id"] == "937d0ba8-918c-4565-9e66-65a9bee988c4"
    assert '"order_id"' in raw
    assert '"decided"' in raw


def test_violation_photo_maps_true():
    body = payload_for_verdict(
        order_id=1,
        agent_verdict="НАРУШЕНИЕ (фото)",
        agent_comment="фото:А3",
        agent_version="v",
        decision_id="d",
    )
    assert body["agent_breach_detected"] is True
    assert body["agent_result_code"] == "violation_photo"


def test_comment_from_detail_uses_agent_fields():
    text = comment_from_detail({"za_chto": "ФОТО_ДОЕЗД", "pometki": "нет подъезда"}, "ЧИСТО")
    assert text == "ФОТО_ДОЕЗД; нет подъезда"
