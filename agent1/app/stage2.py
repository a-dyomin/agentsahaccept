"""Stage2 checklist routing + optional vision + photo-verdict (TZ §6 / §7.2)."""
from __future__ import annotations

import json
import os
import re
from enum import Enum
from pathlib import Path
from typing import Any

from s3_photos import cache_photo, s3_configured


class Checklist(str, Enum):
    KP = "1а"
    SIGNAL = "1б"
    RSO = "1в"
    KGO = "1г"
    NON_PICKUP = "2"


class PhotoVerdict(str, Enum):
    CONFIRMED = "ПОДТВЕРЖДЕНО"
    VIOLATION = "НАРУШЕНИЕ"
    TYPE_MISMATCH = "НЕСООТВЕТСТВИЕ ТИПА"
    SKIPPED = "ПРОПУСК"
    PENDING = "ОЖИДАЕТ"


VISION_URL = os.environ.get("AGENT1_VISION_URL", "").rstrip("/")
VISION_API_KEY = os.environ.get("AGENT1_VISION_API_KEY") or os.environ.get("OPENAI_API_KEY", "")
VISION_MODEL = os.environ.get("AGENT1_VISION_MODEL", "gpt-4o-mini")
VISION_ENABLED = os.environ.get("AGENT1_VISION_ENABLED", "auto").lower()
# USD per 1M tokens (gpt-4o-mini defaults; override via env)
VISION_INPUT_PER_M = float(os.environ.get("AGENT1_VISION_INPUT_USD_PER_M", "0.15"))
VISION_OUTPUT_PER_M = float(os.environ.get("AGENT1_VISION_OUTPUT_USD_PER_M", "0.60"))


def estimate_cost_usd(prompt_tokens: int, completion_tokens: int) -> float:
    return round(
        (prompt_tokens / 1_000_000.0) * VISION_INPUT_PER_M
        + (completion_tokens / 1_000_000.0) * VISION_OUTPUT_PER_M,
        6,
    )

def route_checklist(*, state: str, waste_type: str, site_type: str) -> Checklist | None:
    state_l = (state or "").strip().lower()
    waste = (waste_type or "").strip().upper()
    site = (site_type or "").strip().lower()

    if state_l in {"canceled_by_driver", "cancelled_by_driver"} or "отменена водителем" in state_l:
        return Checklist.NON_PICKUP
    if waste in {"РСО", "RSO"}:
        return Checklist.RSO
    if waste in {"КГО", "KGO"}:
        return Checklist.KGO
    # Greta DB: containers = КП, scheduled = сигнальный метод / МКД
    if site in {"scheduled", "signal"} or "сигнал" in site:
        return Checklist.SIGNAL
    if state_l in {"done", "completed"} or "выполн" in state_l:
        return Checklist.KP
    return None


def route_checklist_for_accept(
    *, state: str, waste_type: str, site_type: str, photo_count: int
) -> Checklist | None:
    """Gold Stage2 set: only done / non-pickup with at least one photo."""
    state_l = (state or "").strip().lower()
    if int(photo_count or 0) <= 0:
        return None
    if state_l not in {
        "done",
        "completed",
        "canceled_by_driver",
        "cancelled_by_driver",
    } and "выполн" not in state_l and "отменена водителем" not in state_l:
        return None
    return route_checklist(state=state, waste_type=waste_type, site_type=site_type)

def _vision_wanted() -> bool:
    if VISION_ENABLED in {"0", "false", "no", "off"}:
        return False
    if VISION_ENABLED in {"1", "true", "yes", "on"}:
        return bool(VISION_API_KEY)
    # auto
    return bool(VISION_API_KEY)


def _parse_vision_json(text: str) -> dict[str, Any]:
    text = (text or "").strip()
    if not text:
        return {}
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        m = re.search(r"\{[\s\S]*\}", text)
        if m:
            try:
                return json.loads(m.group(0))
            except json.JSONDecodeError:
                return {"raw": text}
        return {"raw": text}


def call_vision(checklist: Checklist, photo_paths: list[Path], meta: dict[str, Any]) -> dict[str, Any]:
    """Call OpenAI-compatible vision chat; returns structured answers + photo_verdict + usage."""
    import base64
    import httpx

    if not VISION_API_KEY:
        raise RuntimeError("VISION_API_KEY not set")

    parts: list[dict[str, Any]] = [
        {
            "type": "text",
            "text": (
                f"Чек-лист {checklist.value}. Заявка {meta.get('order_id')}. "
                f"Адрес: {meta.get('site_address') or '—'}. "
                f"Тип отходов: {meta.get('waste_type_name') or '—'}. "
                f"Тип точки: {meta.get('site_stype') or '—'}. "
                f"Состояние: {meta.get('state') or '—'}. "
                f"Причина отмены: {meta.get('fail_reason') or '—'}. "
                f"Комментарий: {meta.get('report_comment') or '—'}.\n"
                "Ответь СТРОГО JSON: "
                '{"answers":{"О1":0|1,...},"photo_verdict":"ПОДТВЕРЖДЕНО|НАРУШЕНИЕ|НЕСООТВЕТСТВИЕ ТИПА",'
                '"za_chto":"...","pometki":"...","comment":"..."}'
            ),
        }
    ]
    for p in photo_paths[:8]:
        data = base64.b64encode(p.read_bytes()).decode("ascii")
        mime = "image/jpeg"
        if p.suffix.lower() in {".png"}:
            mime = "image/png"
        parts.append({"type": "image_url", "image_url": {"url": f"data:{mime};base64,{data}"}})

    base = VISION_URL or "https://api.openai.com/v1"
    headers = {"Authorization": f"Bearer {VISION_API_KEY}", "Content-Type": "application/json"}
    body = {
        "model": VISION_MODEL,
        "messages": [{"role": "user", "content": parts}],
        "temperature": 0,
        "response_format": {"type": "json_object"},
    }
    with httpx.Client(timeout=120.0) as client:
        r = client.post(f"{base}/chat/completions", headers=headers, json=body)
        r.raise_for_status()
        payload = r.json()
        content = payload["choices"][0]["message"]["content"]
        usage = payload.get("usage") or {}
    parsed = _parse_vision_json(content)
    verdict = str(parsed.get("photo_verdict") or PhotoVerdict.PENDING.value)
    prompt_t = int(usage.get("prompt_tokens") or 0)
    completion_t = int(usage.get("completion_tokens") or 0)
    total_t = int(usage.get("total_tokens") or (prompt_t + completion_t))
    cost_usd = estimate_cost_usd(prompt_t, completion_t)
    return {
        "status": "ok",
        "checklist": checklist.value,
        "photo_verdict": verdict,
        "za_chto": parsed.get("za_chto") or "",
        "pometki": parsed.get("pometki") or "",
        "comment": parsed.get("comment") or "",
        "answers": parsed.get("answers") or {},
        "model": VISION_MODEL,
        "usage": {
            "prompt_tokens": prompt_t,
            "completion_tokens": completion_t,
            "total_tokens": total_t,
            "cost_usd": cost_usd,
        },
    }


def run_stage2(payload: dict[str, Any], photos: list[dict[str, Any]]) -> dict[str, Any]:
    """
    photos: [{photo_id, blob_key, ...}]
    Returns stage2 block for agent_detail.
    """
    checklist = route_checklist_for_accept(
        state=str(payload.get("state") or ""),
        waste_type=str(payload.get("waste_type_name") or ""),
        site_type=str(payload.get("site_stype") or ""),
        photo_count=int(payload.get("photo_count") or len(photos) or 0),
    )
    if checklist is None:
        return {
            "status": "skipped",
            "checklist": None,
            "photo_verdict": PhotoVerdict.SKIPPED.value,
            "reason": "no_checklist_for_state",
        }

    day = str(payload.get("day") or "")
    cached: list[Path] = []
    errors: list[str] = []
    for ph in photos:
        key = ph.get("blob_key")
        url = ph.get("photo_url")
        if not key and not url:
            continue
        try:
            path = cache_photo(
                str(key) if key else None,
                photo_id=ph.get("photo_id") or ph.get("id"),
                day=day,
                photo_url=str(url) if url else None,
            )
            if path:
                cached.append(path)
                ph["cached_path"] = str(path)
        except Exception as exc:  # noqa: BLE001
            errors.append(f"{key or url}:{exc}")

    base: dict[str, Any] = {
        "checklist": checklist.value,
        "photos_cached": len(cached),
        "photos_total": len(photos),
        "s3_configured": s3_configured(),
        "errors": errors[:5],
    }

    if not cached:
        base.update(
            {
                "status": "no_photos",
                "photo_verdict": PhotoVerdict.PENDING.value,
                "reason": "no_cached_photos",
            }
        )
        return base

    if not _vision_wanted():
        base.update(
            {
                "status": "deferred",
                "photo_verdict": PhotoVerdict.SKIPPED.value,
                "reason": "vision_disabled_or_no_key",
                "cached_paths": [str(p) for p in cached[:8]],
            }
        )
        return base

    try:
        result = call_vision(checklist, cached, payload)
        result.update({k: base[k] for k in ("photos_cached", "photos_total", "s3_configured")})
        return result
    except Exception as exc:  # noqa: BLE001
        base.update(
            {
                "status": "vision_error",
                "photo_verdict": PhotoVerdict.PENDING.value,
                "reason": str(exc)[:500],
            }
        )
        return base
