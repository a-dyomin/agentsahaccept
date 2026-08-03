"""Stage1 shadow decision from precomputed Greta export fields + Stage2 merge (TZ §7.2)."""
from __future__ import annotations

from typing import Any

from merge_itog import MergeInput, PhotoVerdict, coerce_photo_verdict, merge_itog

STATE_DONE = {"done"}
STATE_NEW = {"created"}  # Greta enum: created ~= Новая
STATE_CANCEL_DRIVER = {"canceled_by_driver"}
STATE_CANCEL_DISPATCHER = {"canceled_by_dispatcher"}
STATE_CANCEL_CONSUMER = {"canceled_by_client"}
STATE_NEED_HUMAN = {"revise", "retry"}  # revise≈уточнение


def _flag(v: Any) -> str:
    if v is None:
        return "ND"
    if v == "ND" or v == "Н/Д":
        return "ND"
    return str(v)


def decide_stage1(payload: dict[str, Any], stage2: dict[str, Any] | None = None) -> dict[str, Any]:
    state = str(payload.get("state") or "")
    photo_count = int(payload.get("photo_count") or 0)
    schedule_id = payload.get("schedule_id")
    geo = _flag(payload.get("geo_flag"))
    track = _flag(payload.get("track_flag"))
    track_exists = bool(payload.get("track_exists"))
    time_f = _flag(payload.get("time_flag"))
    has_report = bool(payload.get("has_report"))
    change_source = str(payload.get("change_source") or "")

    stage1: dict[str, Any] = {
        "state": state,
        "ФОТО_КОЛ": photo_count,
        "ГЕО": geo,
        "ГЕО_МИН_М": payload.get("geo_min_m"),
        "ТРЕК_ЕСТЬ": 1 if track_exists else 0,
        "ТРЕК": track,
        "ТРЕК_М": payload.get("track_min_m"),
        "ВРЕМЯ": time_f,
        "ВРЕМЯ_МИН": payload.get("time_dev_min"),
    }
    pometki: list[str] = []
    za: list[str] = []
    special_human = False
    geo_fail = False
    geo_na_no_coords = False
    schedule_fail = False

    # coverage / not in work
    if (
        schedule_id in (None, "", 0)
        or state in STATE_NEW
        or state == ""
        or state in STATE_CANCEL_DISPATCHER
    ):
        return _pack("К ЧЕЛОВЕКУ", ["охват"], ["не взята в работу"], stage1, payload, stage2)

    if state in STATE_CANCEL_CONSUMER:
        return _pack("ЧИСТО", [], ["отменено потребителем"], stage1, payload, stage2)

    if state in STATE_NEED_HUMAN or (
        state in STATE_DONE and change_source == "backend" and photo_count == 0
    ):
        special_human = True
        pometki.append("требует человека / ручное закрытие")
        return _finalize(
            stage1, payload, stage2, za, pometki,
            special_human=True, geo_fail=False, geo_na_no_coords=False, schedule_fail=False,
        )

    # completed
    if state in STATE_DONE:
        foto_ok = photo_count >= 2
        stage1["ФОТО"] = 1 if foto_ok else 0
        if not foto_ok:
            za.append("ФОТО")
            schedule_fail = True
        if geo == "0":
            za.append("ГЕО")
            geo_fail = True
        if track == "0":
            za.append("ТРЕК")
            schedule_fail = True
        if time_f == "0":
            za.append("ВРЕМЯ")
            schedule_fail = True
        if geo == "ND" and (payload.get("geo_no_coord") or 0) >= photo_count and photo_count > 0:
            pometki.append("место не проверено")
            geo_na_no_coords = True
            return _finalize(
                stage1, payload, stage2, za, pometki,
                special_human=False, geo_fail=geo_fail,
                geo_na_no_coords=True, schedule_fail=schedule_fail,
            )
        if not track_exists and geo == "ND":
            pometki.append("нет ни трека, ни координат")
            return _finalize(
                stage1, payload, stage2, za, pometki,
                special_human=True, geo_fail=geo_fail,
                geo_na_no_coords=False, schedule_fail=schedule_fail,
            )
        if geo == "ND" or track == "ND" or time_f == "ND":
            pometki.append("частично Н/Д")
        return _finalize(
            stage1, payload, stage2, za, pometki,
            special_human=False, geo_fail=geo_fail,
            geo_na_no_coords=geo_na_no_coords, schedule_fail=schedule_fail,
        )

    # no-pickup
    if state in STATE_CANCEL_DRIVER:
        stage1["ОТЧЁТ"] = 1 if has_report else 0
        stage1["ФОТО_ПРЕП"] = 1 if photo_count >= 1 else 0
        if not has_report:
            za.append("ОТЧЁТ")
            schedule_fail = True
        if photo_count < 1:
            za.append("ФОТО_ПРЕП")
            schedule_fail = True
        if track == "0":
            za.append("ТРЕК")
            schedule_fail = True
        if time_f == "0":
            za.append("ВРЕМЯ_ПРЕП")
            schedule_fail = True
        return _finalize(
            stage1, payload, stage2, za, pometki,
            special_human=False, geo_fail=False,
            geo_na_no_coords=False, schedule_fail=schedule_fail,
        )

    return _pack("К ЧЕЛОВЕКУ", ["unknown_state"], pometki, stage1, payload, stage2)


def _finalize(
    stage1: dict[str, Any],
    payload: dict[str, Any],
    stage2: dict[str, Any] | None,
    za: list[str],
    pometki: list[str],
    *,
    special_human: bool,
    geo_fail: bool,
    geo_na_no_coords: bool,
    schedule_fail: bool,
) -> dict[str, Any]:
    s2 = stage2 or {}
    photo_v = coerce_photo_verdict(s2.get("photo_verdict") if s2 else None)
    # If vision deferred/skipped — do not force HUMAN; Stage1 schedule/geo drive ИТОГ
    if photo_v in {PhotoVerdict.SKIPPED, PhotoVerdict.PENDING} and not special_human and not geo_na_no_coords:
        # Stage1-only priority (legacy): geo → photo violation; else schedule; else clean
        if geo_fail:
            itog = "НАРУШЕНИЕ (фото)"
        elif schedule_fail or za:
            itog = "НАРУШЕНИЕ (график)"
        else:
            itog = "ЧИСТО"
        if s2.get("status") == "deferred":
            pometki.append("stage2 отложен (нет vision key)")
        return _pack(itog, za, pometki, stage1, payload, s2 or None)

    itog_enum = merge_itog(
        MergeInput(
            photo_verdict=photo_v,
            geo_fail=geo_fail,
            geo_na_no_coords=geo_na_no_coords,
            schedule_fail=schedule_fail or bool(za),
            special_human=special_human,
        )
    )
    if s2.get("za_chto"):
        za.append(str(s2["za_chto"]))
    if s2.get("pometki"):
        pometki.append(str(s2["pometki"]))
    return _pack(itog_enum.value, za, pometki, stage1, payload, s2 or None)


def _pack(
    itog: str,
    za: list[str],
    pometki: list[str],
    stage1: dict[str, Any],
    payload: dict[str, Any],
    stage2: dict[str, Any] | None,
) -> dict[str, Any]:
    checklist = None
    if stage2:
        checklist = stage2.get("checklist")
    return {
        "agent_verdict": itog,
        "agent_detail": {
            "day": payload.get("day"),
            "itog": itog,
            "za_chto": "; ".join(z for z in za if z),
            "pometki": "; ".join(pometki),
            "checklist": checklist,
            "stage1": stage1,
            "stage2": stage2,
            "human_breach_state": payload.get("human_breach_state"),
        },
        "human_verdict": payload.get("human_breach_state"),
    }


def compare_human(agent_itog: str, human_breach: str | None) -> tuple[int | None, str]:
    """Map Greta breach_state to coarse bucket and compare with agent ИТОГ."""
    if not human_breach or human_breach in {"not_checked", "processed_by_provider"}:
        return None, "human_pending"
    if human_breach == "accepted":
        human_bucket = "ЧИСТО"
    elif human_breach == "rejected":
        human_bucket = "НАРУШЕНИЕ"
    else:
        return None, f"unknown_human:{human_breach}"

    agent_bucket = "НАРУШЕНИЕ" if agent_itog.startswith("НАРУШЕНИЕ") else agent_itog
    if agent_bucket == "К ЧЕЛОВЕКУ":
        return None, "agent_escalated"
    match = 1 if (
        (human_bucket == "ЧИСТО" and agent_bucket == "ЧИСТО")
        or (human_bucket == "НАРУШЕНИЕ" and agent_bucket == "НАРУШЕНИЕ")
    ) else 0
    return match, "ok" if match else f"agent={agent_bucket};human={human_bucket}"
