"""Greta Agent1 accept-review writeback client (verified 2026-08-28).

POST https://greta-api.tinfosys.ru/ai_agents/orders/review_accept
Auth: header ``Token: <secret>`` (not Bearer).
Success: HTTP 204, empty body.

Required: existing Greta ``order_id``. Nested wrappers 404.
``agent_result_code`` is a Rails enum: unknown values return HTTP 500.
"""
from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from datetime import datetime, timezone
from typing import Any, Mapping

WRITEBACK_URL = os.environ.get(
    "GRETA_REVIEW_ACCEPT_URL",
    "https://greta-api.tinfosys.ru/ai_agents/orders/review_accept",
)

# agent_verdict (itog) → Greta fields
VERDICT_TO_GRETA: dict[str, dict[str, Any]] = {
    "ЧИСТО": {
        "agent_status": "decided",
        "agent_result_code": "clean",
        "agent_breach_detected": False,
    },
    "НАРУШЕНИЕ (фото)": {
        "agent_status": "decided",
        "agent_result_code": "violation_photo",
        "agent_breach_detected": True,
    },
    "НАРУШЕНИЕ (график)": {
        "agent_status": "decided",
        "agent_result_code": "violation_schedule",
        "agent_breach_detected": True,
    },
    "К ЧЕЛОВЕКУ": {
        "agent_status": "review_required",
        "agent_result_code": None,
        "agent_breach_detected": None,
    },
}


def comment_from_detail(detail: Mapping[str, Any] | None, verdict: str) -> str:
    """Текст для Greta: за что + пометки; иначе сам вердикт."""
    d = detail or {}
    parts = [str(d.get("za_chto") or "").strip(), str(d.get("pometki") or "").strip()]
    text = "; ".join(p for p in parts if p)
    return text or str(verdict or "")


def payload_for_verdict(
    *,
    order_id: int,
    agent_verdict: str,
    agent_comment: str,
    agent_version: str,
    decision_id: str,
    decided_at: datetime | None = None,
) -> dict[str, Any]:
    mapped = VERDICT_TO_GRETA.get(agent_verdict)
    if not mapped:
        raise ValueError(f"unmapped agent_verdict: {agent_verdict!r}")
    body: dict[str, Any] = {
        "order_id": int(order_id),
        "agent_status": mapped["agent_status"],
        "agent_comment": agent_comment,
        "agent_version": agent_version,
        "decided_at": (decided_at or datetime.now(timezone.utc))
        .astimezone(timezone.utc)
        .strftime("%Y-%m-%dT%H:%M:%SZ"),
        "decision_id": decision_id,
        "agent_breach_detected": mapped["agent_breach_detected"],
    }
    if mapped["agent_result_code"] is not None:
        body["agent_result_code"] = mapped["agent_result_code"]
    return body


def post_review_accept(body: Mapping[str, Any], token: str | None = None) -> int:
    tok = token or os.environ.get("GRETA_REVIEW_ACCEPT_TOKEN")
    if not tok:
        raise RuntimeError("GRETA_REVIEW_ACCEPT_TOKEN is not set")
    data = json.dumps(dict(body), ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        WRITEBACK_URL,
        data=data,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Token": tok,
            "Accept": "*/*",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return int(resp.status)
    except urllib.error.HTTPError as e:
        return int(e.code)
