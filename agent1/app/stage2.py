"""Stage2 checklist routing + optional vision; photo-verdict is programmatic (TZ §6.5)."""
from __future__ import annotations

import json
import os
import re
from enum import Enum
from pathlib import Path
from typing import Any

from checklist_prompts import questions_for
from checklist_verdict import (
    CODES,
    apply_razryv,
    compute_photo_verdict,
    formal_suspect_photo_notes,
    is_vision_blind,
    normalize_answers,
    shot_span_seconds,
    soften_o3,
    to_internal_answers,
)
from photo_meta import prepare_image_for_vision, shot_time_label, sort_photos_by_shot_time
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
# Default: gpt-4o-mini (дешёвый). Для точности на сложных заявках:
#   AGENT1_VISION_MODEL=gpt-4.1  или  gpt-5.4-mini
# На A/B 03.08 новый промпт (А3→«смотри ПОСЛЕ») дал А3=1 у 12/12 бывших нулей уже на mini;
# gpt-4.1 был сопоставим (~3× дороже). Каскад 4.1 — следующий шаг к 90%.
VISION_MODEL = os.environ.get("AGENT1_VISION_MODEL", "gpt-4o-mini")
VISION_ENABLED = os.environ.get("AGENT1_VISION_ENABLED", "auto").lower()
# low|high|auto — low достаточно при пометках ДО/ПОСЛЕ; high — если А3 снова проседает
VISION_DETAIL = os.environ.get("AGENT1_VISION_DETAIL", "low").lower()

# Роли «до/после» из Greta ptype больше не подставляем в промпт (ТЗ Прил. Б / 12.08 п.9).
# Состояния модель определяет по содержимому и времени съёмки.
FALLBACK_NOTE = (
    "Если вопрос неприменим — ответь 0 и начни обоснование словом «неприменимо». "
    "Полярность как в ТЗ: О3/А4/С5/Б5/Н5/Н6 = 1 означает «да, признак/остаток/противоречие есть»."
)
# USD per 1M tokens (defaults for gpt-4o-mini; set env when switching model)
VISION_INPUT_PER_M = float(os.environ.get("AGENT1_VISION_INPUT_USD_PER_M", "0.15"))
VISION_OUTPUT_PER_M = float(os.environ.get("AGENT1_VISION_OUTPUT_USD_PER_M", "0.60"))


def estimate_cost_usd(prompt_tokens: int, completion_tokens: int) -> float:
    return round(
        (prompt_tokens / 1_000_000.0) * VISION_INPUT_PER_M
        + (completion_tokens / 1_000_000.0) * VISION_OUTPUT_PER_M,
        6,
    )

# Greta Site.stype: ровно два значения (UI / CSV).
# DB enum: containers → «Контейнерная площадка», scheduled → «Сигнальный метод».
SITE_SIGNAL = frozenset({"сигнальный метод", "scheduled"})


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
    # 1б только для «Сигнальный метод» (не путать с schedule_id)
    if site in SITE_SIGNAL:
        return Checklist.SIGNAL
    if state_l in {"done", "completed", "retry"} or "выполн" in state_l:
        # «Контейнерная площадка» и любой иной/пустой тип → 1а
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
        "retry",  # TZ §5.4: judge as final done
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


def call_vision(
    checklist: Checklist,
    photo_items: list[dict[str, Any]],
    meta: dict[str, Any],
) -> dict[str, Any]:
    """Call vision for 0/1 answers only; photo_verdict is computed by program (TZ §6.5).

    photo_items: chronologic [{path: Path, time: "ЧЧ:ММ:СС"|None}] — time from filename
    (errors doc §1: Greta DB «Время» is unreliable; on-image stamp unreadable by model).
    MIME sniffed by content, EXIF orientation applied (errors doc §2, §4).
    """
    import base64
    import time

    import httpx

    if not VISION_API_KEY:
        raise RuntimeError("VISION_API_KEY not set")

    codes = ", ".join(CODES.get(checklist.value, ()))
    parts: list[dict[str, Any]] = [
        {
            "type": "text",
            "text": (
                f"Заявка {meta.get('order_id')}. "
                f"Адрес: {meta.get('site_address') or '—'}. "
                f"Тип отходов: {meta.get('waste_type_name') or '—'}. "
                f"Тип точки: {meta.get('site_stype') or '—'}. "
                f"Состояние: {meta.get('state') or '—'}. "
                f"Причина отмены: {meta.get('fail_reason') or '—'}. "
                f"Комментарий: {meta.get('report_comment') or '—'}.\n\n"
                "Снимки идут в хронологическом порядке; время съёмки каждого указано текстом перед ним. "
                "Хронологию определяй ТОЛЬКО по этому времени.\n\n"
                f"{questions_for(checklist.value)}\n\n"
                "НЕ выноси общий вердикт. Только ответы на вопросы.\n"
                f"Ответь СТРОГО JSON: "
                f'{{"answers":{{{codes} as 0|1 (А6 — число)}},'
                f'"answers_why":{{{codes} as краткое обоснование}},'
                f'"comment":"кратко"}}\n'
                f"{FALLBACK_NOTE}"
            ),
        }
    ]
    for idx, item in enumerate(photo_items[:8], start=1):
        p: Path = item["path"]
        t = item.get("time")
        label = f"Снимок {idx}"
        label += f", снят в {t}." if t else ", время съёмки неизвестно."
        parts.append({"type": "text", "text": label})
        img_bytes, mime = prepare_image_for_vision(p)
        data = base64.b64encode(img_bytes).decode("ascii")
        parts.append(
            {
                "type": "image_url",
                "image_url": {"url": f"data:{mime};base64,{data}", "detail": VISION_DETAIL},
            }
        )

    base = VISION_URL or "https://api.openai.com/v1"
    headers = {"Authorization": f"Bearer {VISION_API_KEY}", "Content-Type": "application/json"}
    body = {
        "model": VISION_MODEL,
        "messages": [{"role": "user", "content": parts}],
        "temperature": 0,
        "response_format": {"type": "json_object"},
    }
    max_retries = int(os.environ.get("AGENT1_VISION_RETRIES", "5"))
    payload: dict[str, Any] = {}
    with httpx.Client(timeout=120.0) as client:
        last_exc: Exception | None = None
        for attempt in range(max_retries):
            r = client.post(f"{base}/chat/completions", headers=headers, json=body)
            if r.status_code == 429:
                ra = r.headers.get("retry-after")
                wait = float(ra) if ra and ra.isdigit() else min(60.0, 5.0 * (2**attempt))
                print(f"vision 429 order={meta.get('order_id')} wait={wait}s attempt={attempt+1}", flush=True)
                time.sleep(wait)
                last_exc = httpx.HTTPStatusError("429", request=r.request, response=r)
                continue
            try:
                r.raise_for_status()
            except httpx.HTTPStatusError as exc:
                last_exc = exc
                if r.status_code >= 500 and attempt + 1 < max_retries:
                    time.sleep(min(30.0, 2.0 * (2**attempt)))
                    continue
                raise
            payload = r.json()
            break
        else:
            if last_exc:
                raise last_exc
            raise RuntimeError("vision request failed without response")
        content = payload["choices"][0]["message"]["content"]
        usage = payload.get("usage") or {}
    parsed = _parse_vision_json(content)
    answers = parsed.get("answers") or {}
    answers_why = parsed.get("answers_why") or parsed.get("why") or {}
    if not isinstance(answers_why, dict):
        answers_why = {}
    model_comment = str(parsed.get("comment") or "")
    # Подмешать why в комментарий для soften_o3 / эвристик
    why_blob = " ".join(str(v) for v in answers_why.values() if v)
    evidence_text = f"{model_comment} {why_blob}".strip()
    prompt_t = int(usage.get("prompt_tokens") or 0)
    completion_t = int(usage.get("completion_tokens") or 0)
    total_t = int(usage.get("total_tokens") or (prompt_t + completion_t))
    cost_usd = estimate_cost_usd(prompt_t, completion_t)
    usage_block = {
        "prompt_tokens": prompt_t,
        "completion_tokens": completion_t,
        "total_tokens": total_t,
        "cost_usd": cost_usd,
    }
    # Errors doc §3: model did not actually look (empty/«нет изображений») → human, not verdict.
    # Checked on raw answers: all-zero must not become О3=1 after polarity flip.
    if is_vision_blind(status="ok", answers=answers, comment=model_comment):
        return {
            "status": "blind",
            "checklist": checklist.value,
            "photo_verdict": PhotoVerdict.PENDING.value,
            "reason": "model_did_not_inspect",
            "comment": model_comment,
            "answers": answers,
            "answers_model": answers,
            "answers_why": answers_why,
            "model": VISION_MODEL,
            "usage": usage_block,
        }
    raw_norm = normalize_answers(answers)
    softened = soften_o3(answers, evidence_text)
    internal = to_internal_answers(softened)
    computed = compute_photo_verdict(checklist.value, internal, comment=model_comment)
    filenames = [
        {"filename": it.get("filename") or (Path(it["path"]).name if it.get("path") else "")}
        for it in photo_items
    ]
    span = shot_span_seconds(filenames)
    raz = apply_razryv(
        checklist.value, internal, span_sec=span, comment=model_comment
    )
    photo_verdict = computed.photo_verdict
    za_chto = computed.za_chto
    pometki = computed.pometki
    if raz is not None:
        photo_verdict = raz.photo_verdict
        za_chto = "; ".join(p for p in (za_chto, raz.za_chto) if p)
        pometki = "; ".join(p for p in (pometki, raz.pometki) if p)
    formal_notes = formal_suspect_photo_notes(filenames)
    if formal_notes:
        # Скрин/карта — пометка, не авто-нарушение (уточнение мониторинга 12.08).
        pometki = "; ".join(p for p in (pometki, *formal_notes) if p)
    return {
        "status": "ok",
        "checklist": checklist.value,
        "photo_verdict": photo_verdict,
        "za_chto": za_chto,
        "pometki": pometki,
        "comment": computed.comment,
        "answers": internal,
        "answers_model": answers,
        "answers_why": answers_why,
        "o3_softened": raw_norm.get("О3") == 1 and softened.get("О3") == 0,
        "verdict_source": "program",
        "model": VISION_MODEL,
        "usage": usage_block,
        "shot_span_sec": span,
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
    # Chronologic order by capture time from filename (errors doc §1; DB «Время» unreliable)
    ordered = sort_photos_by_shot_time(list(photos))
    cached: list[Path] = []
    photo_items: list[dict[str, Any]] = []
    errors: list[str] = []
    for ph in ordered:
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
                photo_items.append(
                    {
                        "path": path,
                        "time": shot_time_label(str(ph.get("filename") or "")),
                        "filename": str(ph.get("filename") or path.name),
                    }
                )
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
        result = call_vision(checklist, photo_items, payload)
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
