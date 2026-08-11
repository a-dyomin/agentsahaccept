"""Unit tests for TZ §6.5 programmatic photo verdict + Stage1 branches."""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "agent1" / "app"))

from checklist_verdict import (  # noqa: E402
    VERDICT_CONFIRMED,
    VERDICT_TYPE_MISMATCH,
    VERDICT_VIOLATION,
    compute_photo_verdict,
)
from stage1_shadow import (  # noqa: E402
    VERDICT_FAILED_SHIFT,
    VERDICT_NOT_CHECKED,
    VERDICT_NOT_IN_WORK,
    compare_human,
    decide_stage1,
)


def test_1a_fake():
    r = compute_photo_verdict("1а", {"О1": 1, "О2": 1, "О3": 1, "А0": 1, "А1": 1, "А2": 1, "А3": 1, "А4": 0, "А5": 1})
    assert r.photo_verdict == VERDICT_VIOLATION
    assert "О3" in r.za_chto


def test_1a_type_mismatch():
    r = compute_photo_verdict("1а", {"О1": 1, "О2": 1, "О3": 0, "А0": 0, "А1": 0, "А2": 0, "А3": 0, "А4": 0, "А5": 0})
    assert r.photo_verdict == VERDICT_TYPE_MISMATCH
    assert "А0" in r.za_chto


def test_1a_confirmed_empty():
    r = compute_photo_verdict("1а", {"О1": 1, "О2": 1, "О3": 0, "А0": 1, "А1": 1, "А2": 0, "А3": 1, "А4": 0, "А5": 0})
    assert r.photo_verdict == VERDICT_CONFIRMED
    assert "наполнение" in r.pometki


def test_1a_waste_not_shown():
    r = compute_photo_verdict("1а", {"О1": 1, "О2": 1, "О3": 0, "А0": 1, "А1": 1, "А2": 1, "А3": 0, "А4": 0, "А5": 0})
    assert r.photo_verdict == VERDICT_VIOLATION
    assert "А3" in r.za_chto


def test_1a_a5_fail():
    r = compute_photo_verdict("1а", {"О1": 1, "О2": 1, "О3": 0, "А0": 1, "А1": 1, "А2": 1, "А3": 1, "А4": 0, "А5": 0})
    assert r.photo_verdict == VERDICT_VIOLATION
    assert "А5" in r.za_chto


def test_1v_r1_mismatch():
    r = compute_photo_verdict("1в", {"О1": 1, "О2": 1, "О3": 0, "Р1": 0})
    assert r.photo_verdict == VERDICT_TYPE_MISMATCH


def test_1b_no_accumulation():
    r = compute_photo_verdict("1б", {"О1": 1, "О2": 1, "О3": 0, "С1": 0, "С2": 0, "С3": 0, "С4": 0, "С5": 0, "С6": 0})
    assert r.photo_verdict == VERDICT_CONFIRMED
    assert "накопление" in r.pometki


def test_2_obstacle_ok():
    r = compute_photo_verdict("2", {"О1": 1, "О2": 1, "О3": 0, "Н1": 1, "Н2": 1, "Н3": 1, "Н4": 0, "Н5": 0, "Н6": 0})
    assert r.photo_verdict == VERDICT_CONFIRMED
    assert "госномер" in r.pometki


def test_compare_human_inverted():
    m, _ = compare_human("НАРУШЕНИЕ (фото)", "accepted")
    assert m == 1
    m, _ = compare_human("ЧИСТО", "rejected")
    assert m == 1
    m, reason = compare_human("ЧИСТО", "accepted")
    assert m == 0
    m, reason = compare_human("НЕ ВЗЯТА В РАБОТУ", "accepted")
    assert m is None


def test_not_in_work():
    r = decide_stage1({"state": "created", "schedule_id": 1, "photo_count": 0})
    assert r["agent_verdict"] == VERDICT_NOT_IN_WORK


def test_consumer_skip():
    r = decide_stage1({"state": "canceled_by_client", "schedule_id": 1, "photo_count": 0})
    assert r["agent_verdict"] == VERDICT_NOT_CHECKED


def test_failed_shift():
    r = decide_stage1({"state": "canceled_by_driver", "schedule_id": 1, "failed_shift": True})
    assert r["agent_verdict"] == VERDICT_FAILED_SHIFT


def test_retry_as_done_track_exists_fail():
    r = decide_stage1(
        {
            "state": "retry",
            "schedule_id": 10,
            "photo_count": 2,
            "geo_flag": "1",
            "track_exists": False,
            "track_flag": "ND",
            "time_flag": "ND",
        },
        {"photo_verdict": "ПОДТВЕРЖДЕНО", "status": "ok"},
    )
    assert r["agent_verdict"] == "НАРУШЕНИЕ (график)"
    assert "ТРЕК_ЕСТЬ" in r["agent_detail"]["za_chto"]


def test_route_site_stype_two_values():
    from stage2 import Checklist, route_checklist

    assert (
        route_checklist(state="done", waste_type="ТБО", site_type="Сигнальный метод")
        == Checklist.SIGNAL
    )
    assert (
        route_checklist(state="done", waste_type="ТБО", site_type="scheduled")
        == Checklist.SIGNAL
    )
    assert (
        route_checklist(state="done", waste_type="ТБО", site_type="Контейнерная площадка")
        == Checklist.KP
    )
    assert (
        route_checklist(state="done", waste_type="ТБО", site_type="containers")
        == Checklist.KP
    )


def test_1b_empty_signal_s2_zero_not_fail():
    """Пустая сигнальная точка: С2–С4 = 0 (неприменимо) ≠ НАРУШЕНИЕ."""
    r = compute_photo_verdict(
        "1б",
        {
            "О1": 1, "О2": 1, "О3": 0,
            "С1": 0, "С2": 0, "С3": 0, "С4": 0, "С5": 0, "С6": 0,
        },
    )
    assert r.photo_verdict == VERDICT_CONFIRMED
    assert "С2" not in r.za_chto
    assert "накопление" in r.pometki


def test_1a_a5_zero_inapplicable_when_empty():
    """А5=0 при пустой точке (А2=0,А3=1) — неприменимо, не провал А5."""
    r = compute_photo_verdict(
        "1а",
        {"О1": 1, "О2": 1, "О3": 0, "А0": 1, "А1": 1, "А2": 0, "А3": 1, "А4": 0, "А5": 0},
    )
    assert r.photo_verdict == VERDICT_CONFIRMED
    assert "А5" not in r.za_chto


def test_stage2_missing_not_clean():
    r = decide_stage1(
        {
            "state": "done",
            "schedule_id": 1,
            "photo_count": 2,
            "geo_flag": "1",
            "track_exists": True,
            "track_flag": "1",
            "time_flag": "1",
        },
        {"status": "deferred", "photo_verdict": "ПРОПУСК", "reason": "vision_disabled_or_no_key"},
    )
    assert r["agent_verdict"] == "К ЧЕЛОВЕКУ"
    assert "Stage2" in r["agent_detail"]["pometki"] or "stage2" in r["agent_detail"]["pometki"].lower()


def test_transfered():
    from stage1_shadow import VERDICT_TRANSFERRED

    r = decide_stage1({"state": "done", "schedule_id": 1, "transfered": True, "photo_count": 2})
    assert r["agent_verdict"] == VERDICT_TRANSFERRED


def test_detail_fields_in_stage1():
    r = decide_stage1(
        {
            "state": "done",
            "schedule_id": 1,
            "photo_count": 2,
            "geo_flag": "0",
            "geo_min_m": 412.5,
            "geo_out": 2,
            "geo_no_coord": 0,
            "track_exists": True,
            "track_flag": "1",
            "track_min_m": 30.0,
            "time_flag": "1",
            "time_dev_min": 1.2,
        },
        {"photo_verdict": "ПОДТВЕРЖДЕНО", "status": "ok"},
    )
    s1 = r["agent_detail"]["stage1"]
    assert s1["ГЕО_МИН_М"] == 412.5
    assert s1["ГЕО_ВНЕ"] == 2
    assert s1["ГЕО_БЕЗ_КООРД"] == 0
    assert s1["ТРЕК_М"] == 30.0
    assert s1["ВРЕМЯ_МИН"] == 1.2


def test_geo_photo_fail_is_overridden_by_wialon_and_confirmed_photos():
    """Глушёный GPS фото не валит акцепт, если Wialon и Stage2 подтверждают точку."""
    r = decide_stage1(
        {
            "state": "done",
            "schedule_id": 1,
            "photo_count": 2,
            "geo_flag": "0",
            "geo_min_m": 4980.0,
            "geo_out": 2,
            "geo_no_coord": 0,
            "track_exists": True,
            "track_flag": "1",
            "track_min_m": 24.0,
            "time_flag": "1",
        },
        {"photo_verdict": "ПОДТВЕРЖДЕНО", "status": "ok"},
    )

    assert r["agent_verdict"] == "ЧИСТО"
    assert "ГЕО" not in r["agent_detail"]["za_chto"]
    assert r["agent_detail"]["stage1"]["ГЕО_ПО_ТРЕКУ"] == 1
    assert "Wialon" in r["agent_detail"]["pometki"]


def test_geo_photo_fail_not_overridden_when_photos_violate():
    """Трек не должен скрывать самостоятельное нарушение содержания фото."""
    r = decide_stage1(
        {
            "state": "done",
            "schedule_id": 1,
            "photo_count": 2,
            "geo_flag": "0",
            "geo_min_m": 4980.0,
            "geo_out": 2,
            "geo_no_coord": 0,
            "track_exists": True,
            "track_flag": "1",
            "track_min_m": 24.0,
            "time_flag": "1",
        },
        {
            "photo_verdict": "НАРУШЕНИЕ",
            "status": "ok",
            "za_chto": "фото:А3",
        },
    )

    assert r["agent_verdict"] == "НАРУШЕНИЕ (фото)"
    assert "ГЕО" in r["agent_detail"]["za_chto"]
    assert "фото:А3" in r["agent_detail"]["za_chto"]
    assert "ГЕО_ПО_ТРЕКУ" not in r["agent_detail"]["stage1"]


def test_1g_b2_b5_contradiction_not_violation():
    """Б2=0 + Б5=1 — спорные ответы: считаем Б2=1, дальше Б3/Б4 (правка ТЗ 04.08)."""
    r = compute_photo_verdict(
        "1г",
        {"О1": 1, "О2": 1, "О3": 0, "Б1": 1, "Б2": 0, "Б3": 1, "Б4": 1, "Б5": 1},
    )
    assert r.photo_verdict == VERDICT_CONFIRMED
    assert "Б2" not in r.za_chto
    assert "спорные ответы Б2/Б5" in r.pometki


def test_1g_b2_zero_without_b5_still_violation():
    r = compute_photo_verdict(
        "1г",
        {"О1": 1, "О2": 1, "О3": 0, "Б1": 1, "Б2": 0, "Б3": 0, "Б4": 0, "Б5": 0},
    )
    assert r.photo_verdict == VERDICT_VIOLATION
    assert "Б2" in r.za_chto


def test_1g_b2_b5_contradiction_then_b3_fail():
    """Спорные Б2/Б5 снимают провал Б2, но Б3=0 остаётся нарушением."""
    r = compute_photo_verdict(
        "1г",
        {"О1": 1, "О2": 1, "О3": 0, "Б1": 1, "Б2": 0, "Б3": 0, "Б4": 1, "Б5": 1},
    )
    assert r.photo_verdict == VERDICT_VIOLATION
    assert "Б3" in r.za_chto
    assert "Б2" not in r.za_chto
    assert "спорные ответы Б2/Б5" in r.pometki


def test_o3_polarity_inverted_from_model():
    """Модель отвечает «снимки подлинные»: 1 → внутренняя О3=0 (подделки нет)."""
    from checklist_verdict import to_internal_answers

    ok = to_internal_answers({"О1": 1, "О2": 1, "О3": 1, "А0": 1})
    assert ok["О3"] == 0
    fake = to_internal_answers({"О1": 1, "О2": 1, "О3": 0, "А0": 1})
    assert fake["О3"] == 1
    # прочие коды не трогаем
    assert ok["О1"] == 1 and ok["А0"] == 1


def test_o3_authentic_photos_not_violation():
    """Подлинные снимки (модель О3=1) больше не дают «фото:О3»."""
    from checklist_verdict import to_internal_answers

    a = to_internal_answers(
        {"О1": 1, "О2": 1, "О3": 1, "А0": 1, "А1": 1, "А2": 1, "А3": 1, "А4": 1, "А5": 1}
    )
    r = compute_photo_verdict("1а", a)
    assert r.photo_verdict == VERDICT_CONFIRMED
    assert "О3" not in r.za_chto


def test_soften_o3_drops_soft_doubt():
    from checklist_verdict import soften_o3, to_internal_answers

    soft = soften_o3(
        {"О3": 0, "А3": 1},
        "Снимки соответствуют требованиям, но есть вопросы по подлинности.",
    )
    assert soft["О3"] == 1
    assert to_internal_answers(soft)["О3"] == 0

    hard = soften_o3(
        {"О3": 0, "А3": 1},
        "Это скрин карты, а не фото с места.",
    )
    assert hard["О3"] == 0
    assert to_internal_answers(hard)["О3"] == 1

    already_ok = soften_o3({"О3": 1}, "ок")
    assert already_ok["О3"] == 1


def test_a4_h5_polarity_inverted():
    """А4 и Н5 тоже спрашиваются позитивно: 1 от модели = нарушения нет."""
    from checklist_verdict import to_internal_answers

    clean = to_internal_answers({"А4": 1, "Н5": 1, "С5": 1, "Б5": 1, "Н6": 1})
    assert clean["А4"] == 0 and clean["Н5"] == 0
    assert clean["С5"] == 0 and clean["Б5"] == 0 and clean["Н6"] == 0
    bad = to_internal_answers({"А4": 0, "Н5": 0, "С5": 0, "Б5": 0, "Н6": 0})
    assert bad["А4"] == 1 and bad["Н5"] == 1
    assert bad["С5"] == 1 and bad["Б5"] == 1 and bad["Н6"] == 1

    ok = compute_photo_verdict(
        "1а",
        to_internal_answers(
            {"О1": 1, "О2": 1, "О3": 1, "А0": 1, "А1": 1, "А2": 1, "А3": 1, "А4": 1, "А5": 1}
        ),
    )
    assert ok.photo_verdict == VERDICT_CONFIRMED
    leftovers = compute_photo_verdict(
        "1а",
        to_internal_answers(
            {"О1": 1, "О2": 1, "О3": 1, "А0": 1, "А1": 1, "А2": 1, "А3": 1, "А4": 0, "А5": 1}
        ),
    )
    assert leftovers.photo_verdict == VERDICT_VIOLATION
    assert "А4" in leftovers.za_chto


def test_prompts_reference_before_after():
    from checklist_prompts import questions_for

    q1a = questions_for("1а")
    assert "ПОСЛЕ вывоза" in q1a
    assert "Пара ДО+ПОСЛЕ" in q1a or "ДО+ПОСЛЕ" in q1a
    q2 = questions_for("2")
    assert "по прибытии" in q2 or "перед отъездом" in q2


def test_photo_frame_labels_before_after():
    """Кадры уходят в модель с пометкой ДО/ПОСЛЕ из ptype Гретты."""
    import sys
    from pathlib import Path as P

    sys.path.insert(0, str(P(__file__).resolve().parents[1] / "agent1" / "app"))
    from stage2 import frame_label

    assert frame_label("1а", "site_before") == "ДО вывоза"
    assert frame_label("1а", "site_after") == "ПОСЛЕ вывоза"
    assert frame_label("1г", "site_after") == "ПОСЛЕ вывоза"
    assert frame_label("1а", None) == ""
    # невывоз: вывоза не было, ярлык «ПОСЛЕ вывоза» давал О1=0 в 95% заявок
    assert "вывоз" not in frame_label("2", "site_after")
    assert frame_label("2", "site_after") == "перед отъездом с точки"


def test_is_vision_blind():
    from checklist_verdict import is_vision_blind

    assert is_vision_blind(status="no_photos")
    assert is_vision_blind(status="vision_error")
    assert is_vision_blind(status="ok", answers={}, comment="")
    assert is_vision_blind(
        status="ok",
        answers={"О1": 0, "О2": 0, "О3": 0, "А0": 0},
        comment="Нет изображений для анализа",
    )
    assert not is_vision_blind(
        status="ok",
        answers={"О1": 1, "О2": 1, "О3": 0, "А0": 1},
        comment="площадка чистая",
    )
    # все нули по существу (реальный «плохой» ответ) — не слепота
    assert not is_vision_blind(
        status="ok",
        answers={"О1": 0, "О2": 0, "О3": 0},
        comment="кадры сняты из кабины",
    )


def test_blind_stage2_goes_to_human_even_with_geo_fail():
    """Errors doc §3: модель не посмотрела → К ЧЕЛОВЕКУ, даже при провале ГЕО/графика."""
    r = decide_stage1(
        {
            "state": "done",
            "schedule_id": 1,
            "photo_count": 2,
            "geo_flag": "0",
            "geo_min_m": 500.0,
            "track_exists": True,
            "track_flag": "1",
            "time_flag": "1",
        },
        {"status": "blind", "photo_verdict": "ОЖИДАЕТ", "reason": "model_did_not_inspect"},
    )
    assert r["agent_verdict"] == "К ЧЕЛОВЕКУ"
    assert "не посмотрел" in r["agent_detail"]["pometki"]


def test_shot_time_from_filename():
    import sys
    from pathlib import Path as P

    sys.path.insert(0, str(P(__file__).resolve().parents[1] / "agent1" / "app"))
    from photo_meta import shot_time_label, sniff_image_mime, sort_photos_by_shot_time

    assert shot_time_label("JPEG_20260802_091712.jpg") == "09:17:12"
    assert shot_time_label("2026-08-02_21-38-29.png") == "21:38:29"
    assert shot_time_label("М. Пурга-Миндерево.PNG") is None

    photos = [
        {"photo_id": 2, "filename": "JPEG_20260802_122241.jpg"},
        {"photo_id": 1, "filename": "JPEG_20260802_122126.jpg"},
        {"photo_id": 3, "filename": "weird.png"},
    ]
    ordered = sort_photos_by_shot_time(photos)
    assert [p["photo_id"] for p in ordered] == [1, 2, 3]

    assert sniff_image_mime(b"\x89PNG\r\n\x1a\n" + b"x" * 8) == "image/png"
    assert sniff_image_mime(b"\xff\xd8\xff\xe0" + b"x" * 8) == "image/jpeg"


def test_accept_gold_day_constant():
    from accept_test import GOLD_DAY

    assert GOLD_DAY == "2026-07-12"


def test_nonpickup_foto_doezd():
    r = decide_stage1(
        {
            "state": "canceled_by_driver",
            "schedule_id": 10,
            "photo_count": 1,
            "has_report": True,
            "track_exists": True,
            "track_flag": "1",
            "time_flag": "1",
            "foto_doezd_flag": "0",
            "foto_doezd_m": 250,
        },
        {"photo_verdict": "ПОДТВЕРЖДЕНО", "status": "ok"},
    )
    assert r["agent_verdict"] == "НАРУШЕНИЕ (график)"
    assert "ФОТО_ДОЕЗД" in r["agent_detail"]["za_chto"]
