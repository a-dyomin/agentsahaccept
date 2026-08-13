"""Stage1 shadow decision from precomputed Greta export fields + Stage2 merge (TZ §5 / §7.2)."""
from __future__ import annotations

import re
from typing import Any

from merge_itog import MergeInput, PhotoVerdict, coerce_photo_verdict, merge_itog

STATE_DONE = {"done", "retry"}  # TZ §5.4: retry = judge as final done
STATE_NEW = {"created"}  # Greta enum: created ~= Новая
STATE_CANCEL_DRIVER = {"canceled_by_driver"}
STATE_CANCEL_DISPATCHER = {"canceled_by_dispatcher"}
STATE_CANCEL_CONSUMER = {"canceled_by_client"}
STATE_REVISE = {"revise"}  # только уточнение → человек

VERDICT_NOT_IN_WORK = "НЕ ВЗЯТА В РАБОТУ"
VERDICT_NOT_CHECKED = "НЕ ПРОВЕРЯЕТСЯ"
VERDICT_FAILED_SHIFT = "СМЕНА НЕ ВЫШЛА"
VERDICT_TRANSFERRED = "ПЕРЕНЕСЕНА"  # документ «Перенос» из 1С (TZ §5.4)

# На невывозе эти флаги не должны автоматом давать «НАРУШЕНИЕ (график)»,
# если причина — уважительный блок проезда и фото её не опровергает.
_SOFT_SCHEDULE_FLAGS = frozenset({"ТРЕК", "ТРЕК_ЕСТЬ", "ФОТО_ДОЕЗД", "ВРЕМЯ_ПРЕП", "ВРЕМЯ"})

# Словарь уважительных причин невывоза (fail_reason + комментарий отчёта).
_ACCESS_BLOCK_PATTERNS: tuple[tuple[re.Pattern[str], str], ...] = tuple(
    (re.compile(pat, re.IGNORECASE), label)
    for pat, label in (
        (r"не\s*проехать|невозможно\s+проехать", "не проехать"),
        (r"нет\s+подъезд|подъездн\w*\s+нет|нет\s+подъезда", "нет подъезда"),
        (r"невозможно\s+подъехать|не\s+подъехать", "невозможно подъехать"),
        (r"закрыт\w*\s+проезд|проезд\w*\s+закрыт", "закрыт проезд"),
        (r"ворот[аыуе]|шлагбаум|забор", "ворота/шлагбаум"),
        (r"размыт|размыл|ливн|дожд|гряз[ьи]|снег|коле[яи]|провалива", "погода/дорога"),
        (r"нет\s+разворот", "нет разворота"),
        (
            r"автомобил\w*.{0,20}меша|машин\w*.{0,20}(меша|перекры|стоя)|"
            r"припаркован|перекрыт\w*\s+авто",
            "автомобиль/помеха",
        ),
        (r"нет\s+возможност\w*\s+проезд", "нет возможности проезда"),
    )
)


def _flag(v: Any) -> str:
    if v is None:
        return "ND"
    if v == "ND" or v == "Н/Д":
        return "ND"
    return str(v)


def match_access_block_reason(text: str | None) -> str | None:
    """Вернуть ярлык уважительной причины блока проезда или None."""
    if not text:
        return None
    raw = str(text).strip()
    if not raw:
        return None
    for pat, label in _ACCESS_BLOCK_PATTERNS:
        if pat.search(raw):
            return label
    return None


def legitimate_access_block_reason(payload: dict[str, Any]) -> str | None:
    """Искать уважительную причину в fail_reason и комментарии отчёта."""
    for key in ("fail_reason", "report_comment"):
        label = match_access_block_reason(payload.get(key))
        if label:
            return label
    # Иногда оба поля склеены в одной строке при ручных тестах.
    joined = " ".join(
        str(payload.get(k) or "").strip()
        for k in ("fail_reason", "report_comment")
        if payload.get(k)
    )
    return match_access_block_reason(joined) if joined else None


def _soften_nonpickup_schedule_for_access(
    *,
    za: list[str],
    pometki: list[str],
    schedule_fail: bool,
    payload: dict[str, Any],
    stage2: dict[str, Any] | None,
    has_report: bool,
    photo_count: int,
) -> tuple[list[str], list[str], bool]:
    """П.3–4: не авто-НАРУШЕНИЕ (график) по ТРЕК/ФОТО_ДОЕЗД при уважительном блоке.

    Условия: есть отчёт, есть фото, причина из словаря, Stage2 не опровергает
    (photo_verdict ≠ НАРУШЕНИЕ / VIOLATION). Жёсткие ОТЧЁТ/ФОТО_ПРЕП не смягчаем.
    """
    if not has_report or photo_count < 1:
        return za, pometki, schedule_fail
    reason = legitimate_access_block_reason(payload)
    if not reason:
        return za, pometki, schedule_fail
    photo_v = coerce_photo_verdict(
        (stage2 or {}).get("photo_verdict") if stage2 else None
    )
    # Фото опровергает причину (Н5 / VIOLATION) — график не смягчаем.
    if photo_v == PhotoVerdict.VIOLATION:
        return za, pometki, schedule_fail

    soft = [z for z in za if z in _SOFT_SCHEDULE_FLAGS]
    if not soft:
        return za, pometki, schedule_fail

    hard = [z for z in za if z not in _SOFT_SCHEDULE_FLAGS]
    pometki.append(
        f"уважительный блок проезда («{reason}»): "
        f"{', '.join(soft)} → пометки, не авто-нарушение графика"
    )
    schedule_fail = bool(hard)
    return hard, pometki, schedule_fail


def decide_stage1(payload: dict[str, Any], stage2: dict[str, Any] | None = None) -> dict[str, Any]:
    state = str(payload.get("state") or "")
    photo_count = int(payload.get("photo_count") or 0)
    schedule_id = payload.get("schedule_id")
    geo = _flag(payload.get("geo_flag"))
    track = _flag(payload.get("track_flag"))
    track_exists = bool(payload.get("track_exists"))
    time_f = _flag(payload.get("time_flag"))
    foto_doezd = _flag(payload.get("foto_doezd_flag"))
    has_report = bool(payload.get("has_report"))
    change_source = str(payload.get("change_source") or "")

    stage1: dict[str, Any] = {
        "state": state,
        "ФОТО_КОЛ": photo_count,
        "ГЕО": geo,
        "ГЕО_МИН_М": payload.get("geo_min_m"),
        "ГЕО_ВНЕ": payload.get("geo_out"),
        "ГЕО_БЕЗ_КООРД": payload.get("geo_no_coord"),
        "ТРЕК_ЕСТЬ": 1 if track_exists else 0,
        "ТРЕК": track if track_exists else "ND",
        "ТРЕК_М": payload.get("track_min_m") if track_exists else None,
        "ВРЕМЯ": time_f if track_exists else "ND",
        "ВРЕМЯ_МИН": payload.get("time_dev_min") if track_exists else None,
        "ФОТО_ДОЕЗД": foto_doezd if track_exists else "ND",
        "ФОТО_ДОЕЗД_М": payload.get("foto_doezd_m") if track_exists else None,
    }
    pometki: list[str] = []
    za: list[str] = []
    geo_fail = False
    geo_na_no_coords = False
    schedule_fail = False

    # TZ §5.4 — перенос из 1С: справочная строка, в охват/суд не входит
    if payload.get("transfered") in (True, 1, "1", "true", "True"):
        return _pack(
            VERDICT_TRANSFERRED,
            [],
            ["перенесена документом 1С; в пропуски не включена"],
            stage1,
            payload,
            None,
        )

    # TZ §5.4 failed shift — one incident, no per-order Stage1/2 math
    if payload.get("failed_shift"):
        return _pack(
            VERDICT_FAILED_SHIFT,
            [],
            ["смена не вышла; по-заявочные проверки не применялись"],
            stage1,
            payload,
            None,
        )

    # TZ §5.1 coverage / not in work → table A (not К ЧЕЛОВЕКУ)
    if (
        schedule_id in (None, "", 0)
        or state in STATE_NEW
        or state == ""
        or state in STATE_CANCEL_DISPATCHER
    ):
        return _pack(VERDICT_NOT_IN_WORK, ["охват"], ["не взята в работу"], stage1, payload, None)

    # TZ §5.1 consumer cancel — not checked
    if state in STATE_CANCEL_CONSUMER:
        return _pack(VERDICT_NOT_CHECKED, [], ["отменено потребителем"], stage1, payload, None)

    # TZ §5.4 revise only → human; retry is in STATE_DONE
    if state in STATE_REVISE or (
        state in {"done"} and change_source == "backend" and photo_count == 0
    ):
        if change_source == "backend" and photo_count == 0:
            pometki.append("закрыто вручную регоператором")
        else:
            pometki.append("требует уточнения")
        return _finalize(
            stage1, payload, stage2, za, pometki,
            special_human=True, geo_fail=False, geo_na_no_coords=False, schedule_fail=False,
        )

    # completed (+ retry as done)
    if state in STATE_DONE or "выполн" in state.lower():
        foto_ok = photo_count >= 2
        stage1["ФОТО"] = 1 if foto_ok else 0
        if not foto_ok:
            za.append("ФОТО")
            schedule_fail = True
        if geo == "0":
            za.append("ГЕО")
            geo_fail = True
        if not track_exists:
            za.append("ТРЕК_ЕСТЬ")
            schedule_fail = True
        else:
            if track == "0":
                za.append("ТРЕК")
                schedule_fail = True
            if time_f == "0":
                za.append("ВРЕМЯ")
                schedule_fail = True
        # GPS телефона может быть заглушен/подменён на километры. Если независимый
        # Wialon подтверждает, что машина была у площадки, а Stage2 подтвердил
        # содержание фото, координаты самого снимка не считаем нарушением.
        photo_v = coerce_photo_verdict(
            (stage2 or {}).get("photo_verdict") if stage2 else None
        )
        if geo_fail and track_exists and track == "1" and photo_v == PhotoVerdict.CONFIRMED:
            geo_fail = False
            za = [item for item in za if item != "ГЕО"]
            stage1["ГЕО_ПО_ТРЕКУ"] = 1
            pometki.append(
                "ГЕО фото вне порога; место подтверждено треком Wialon и содержанием фото"
            )
        if geo == "ND" and (payload.get("geo_no_coord") or 0) >= photo_count and photo_count > 0:
            # TZ §7.5 / 12.08: нет GPS у фото, но трек подтверждает доезд → не человеку.
            if track_exists and track == "1":
                stage1["ГЕО_ПО_ТРЕКУ"] = 1
                pometki.append(
                    "у снимков нет координат, место подтверждено треком"
                )
            else:
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
        if geo == "ND" or (track_exists and (track == "ND" or time_f == "ND")):
            pometki.append("частично Н/Д")
        return _finalize(
            stage1, payload, stage2, za, pometki,
            special_human=False, geo_fail=geo_fail,
            geo_na_no_coords=geo_na_no_coords, schedule_fail=schedule_fail,
        )

    # no-pickup — 6 checks (TZ §5.3)
    if state in STATE_CANCEL_DRIVER or "отменена водителем" in state.lower():
        stage1["ОТЧЁТ"] = 1 if has_report else 0
        stage1["ФОТО_ПРЕП"] = 1 if photo_count >= 1 else 0
        stage1["ФОТО_ПРЕП_КОЛ"] = photo_count
        if not has_report:
            za.append("ОТЧЁТ")
            schedule_fail = True
        if photo_count < 1:
            za.append("ФОТО_ПРЕП")
            schedule_fail = True
        if not track_exists:
            za.append("ТРЕК_ЕСТЬ")
            schedule_fail = True
            # TZ: checks 4–6 become ND without track
            stage1["ТРЕК"] = "ND"
            stage1["ФОТО_ДОЕЗД"] = "ND"
            stage1["ВРЕМЯ"] = "ND"
            stage1["ВРЕМЯ_ПРЕП"] = "ND"
        else:
            if track == "0":
                za.append("ТРЕК")
                schedule_fail = True
            if foto_doezd == "0":
                za.append("ФОТО_ДОЕЗД")
                schedule_fail = True
            if time_f == "0":
                za.append("ВРЕМЯ_ПРЕП")
                schedule_fail = True
            stage1["ВРЕМЯ_ПРЕП"] = time_f
            stage1["ВРЕМЯ_ПРЕП_МИН"] = payload.get("time_dev_min")
        za, pometki, schedule_fail = _soften_nonpickup_schedule_for_access(
            za=za,
            pometki=pometki,
            schedule_fail=schedule_fail,
            payload=payload,
            stage2=stage2,
            has_report=has_report,
            photo_count=photo_count,
        )
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
    # TZ §7.2: ЧИСТО только при фото-вердикте ПОДТВЕРЖДЕНО.
    # Нет Stage2 / ошибка / deferred → не маскируем как ЧИСТО.
    if photo_v == PhotoVerdict.PENDING and not special_human:
        # Errors doc §3: model did not inspect (no_photos / vision_error / blind answers)
        # → «К ЧЕЛОВЕКУ», never a violation; stage1 flags go to pometki.
        reason = str(s2.get("reason") or s2.get("status") or "нет фото-вердикта")
        pometki.append(f"Stage2 не посмотрел фото ({reason}) — проверка человеком")
        if geo_fail:
            pometki.append("ГЕО вне порога (Этап 1)")
        if schedule_fail or za:
            pometki.append("график: " + ("; ".join(za) if za else "провал"))
        return _pack("К ЧЕЛОВЕКУ", za, pometki, stage1, payload, s2 or None)

    if photo_v == PhotoVerdict.SKIPPED and not special_human and not geo_na_no_coords:
        reason = str(s2.get("reason") or s2.get("status") or "нет фото-вердикта")
        if geo_fail or schedule_fail or za:
            # Без осмотра снимков ярлык «(фото)» не ставим (12.08).
            itog = "НАРУШЕНИЕ (график)"
        else:
            itog = "К ЧЕЛОВЕКУ"
            pometki.append(f"Stage2 не дал фото-вердикт ({reason})")
        if s2.get("status") == "deferred":
            pometki.append("stage2 отложен (нет vision key)")
        return _pack(itog, za, pometki, stage1, payload, s2 or None)

    # TYPE_MISMATCH + schedule/geo fail → violation; mismatch goes to pometki (TZ §7.2)
    if photo_v == PhotoVerdict.TYPE_MISMATCH and (geo_fail or schedule_fail or za):
        if s2.get("pometki"):
            pometki.append(str(s2["pometki"]))
        pometki.append("НЕСООТВЕТСТВИЕ ТИПА (в пометках)")
        if s2.get("za_chto"):
            za.append(str(s2["za_chto"]))
        itog_enum = merge_itog(
            MergeInput(
                photo_verdict=photo_v,
                geo_fail=geo_fail,
                geo_na_no_coords=geo_na_no_coords,
                schedule_fail=schedule_fail or bool(za),
                special_human=False,
            )
        )
        return _pack(itog_enum.value, za, pometki, stage1, payload, s2 or None)

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
    """Map Greta breach_state to coarse bucket and compare with agent ИТОГ.

    Greta accept card = violation to carrier: accepted ≈ violation confirmed,
    rejected ≈ «Не нарушение» / no violation (TZ / ops practice).
    """
    if not human_breach or human_breach in {"not_checked", "processed_by_provider"}:
        return None, "human_pending"
    hb = human_breach.strip().lower()
    if hb in {"accepted", "принят", "нарушение"}:
        human_bucket = "НАРУШЕНИЕ"
    elif hb in {"rejected", "отклонён", "отклонен", "не нарушение", "не_нарушение"}:
        human_bucket = "ЧИСТО"
    else:
        return None, f"unknown_human:{human_breach}"

    # Coverage / skip / failed-shift are not comparable to accept card
    if agent_itog in {
        VERDICT_NOT_IN_WORK,
        VERDICT_NOT_CHECKED,
        VERDICT_FAILED_SHIFT,
        VERDICT_TRANSFERRED,
    }:
        return None, "agent_out_of_scope"

    agent_bucket = "НАРУШЕНИЕ" if agent_itog.startswith("НАРУШЕНИЕ") else agent_itog
    if agent_bucket == "К ЧЕЛОВЕКУ":
        return None, "agent_escalated"
    match = 1 if (
        (human_bucket == "ЧИСТО" and agent_bucket == "ЧИСТО")
        or (human_bucket == "НАРУШЕНИЕ" and agent_bucket == "НАРУШЕНИЕ")
    ) else 0
    return match, "ok" if match else f"agent={agent_bucket};human={human_bucket}"
