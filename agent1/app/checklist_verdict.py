"""Programmatic photo-verdict from checklist answers (TZ §6.5 / Appendix B)."""
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any


VERDICT_CONFIRMED = "ПОДТВЕРЖДЕНО"
VERDICT_VIOLATION = "НАРУШЕНИЕ"
VERDICT_TYPE_MISMATCH = "НЕСООТВЕТСТВИЕ ТИПА"

# Question codes expected from the model per checklist
CODES: dict[str, tuple[str, ...]] = {
    "1а": ("О1", "О2", "О3", "А0", "А1", "А2", "А3", "А4", "А5", "А6"),
    "1б": ("О1", "О2", "О3", "С1", "С2", "С3", "С4", "С5", "С6"),
    "1в": ("О1", "О2", "О3", "Р1"),
    "1г": ("О1", "О2", "О3", "Б1", "Б2", "Б3", "Б4", "Б5"),
    "2": ("О1", "О2", "О3", "Н1", "Н2", "Н3", "Н4", "Н5", "Н6"),
}


@dataclass
class VerdictResult:
    photo_verdict: str
    za_chto: str
    pometki: str
    comment: str


def _as_int(v: Any) -> int | None:
    if v is None:
        return None
    if isinstance(v, bool):
        return int(v)
    if isinstance(v, (int, float)):
        return int(v)
    if isinstance(v, dict):
        for key in ("value", "answer", "a", "v"):
            if key in v:
                return _as_int(v[key])
        return None
    s = str(v).strip()
    if not s:
        return None
    try:
        return int(float(s))
    except ValueError:
        low = s.lower()
        if low in {"да", "yes", "true"}:
            return 1
        if low in {"нет", "no", "false"}:
            return 0
        return None


_CODE_TRANS = {
    "O1": "О1", "O2": "О2", "O3": "О3",
    "A0": "А0", "A1": "А1", "A2": "А2", "A3": "А3", "A4": "А4", "A5": "А5", "A6": "А6",
    "C1": "С1", "C2": "С2", "C3": "С3", "C4": "С4", "C5": "С5", "C6": "С6",
    "B1": "Б1", "B2": "Б2", "B3": "Б3", "B4": "Б4", "B5": "Б5",
    "H1": "Н1", "H2": "Н2", "H3": "Н3", "H4": "Н4", "H5": "Н5", "H6": "Н6",
    "R1": "Р1",
}


# TZ Appendix B polarity (12.08): questions match internal semantics directly.
# О3/А4/С5/Б5/Н5/Н6: 1 = «да, есть признак/остаток/противоречие». No inversion.
POSITIVE_CODES: tuple[str, ...] = ()

# Hard evidence of a fake frame. Soft «есть вопросы по подлинности» without these is noise.
_O3_HARD_FAKE = re.compile(
    r"скрин|screenshot|\bкарт[аыеу]\b|google\s*maps|яндекс\.?\s*карт|экран|"
    r"не с места|чужое место|один и тот же файл|дубль одного|распечат",
    re.IGNORECASE,
)

# Greta app filename: JPEG_YYYYMMDD_HHMMSS (kept for docs/tests)
_JPEG_APP_NAME = re.compile(r"^JPEG_\d{8}_\d{6}(?:\D|$)", re.IGNORECASE)


def soften_o3(raw: Any, comment: str = "") -> dict[str, int]:
    """Drop weak О3=1 (TZ: признаки подделки) without hard evidence in comment/why."""
    a = normalize_answers(raw)
    if a.get("О3") != 1:
        return a
    if _O3_HARD_FAKE.search(comment or ""):
        return a
    a["О3"] = 0
    return a


def to_internal_answers(raw: Any) -> dict[str, int]:
    """Model answers → internal semantics (TZ polarity; POSITIVE_CODES empty)."""
    a = normalize_answers(raw)
    for code in POSITIVE_CODES:
        if code in a:
            a[code] = 0 if a[code] else 1
    return a


def formal_suspect_photo_notes(photos: list[dict[str, Any]] | None) -> list[str]:
    """Heuristic map/screenshot flags → пометки, не авто-О3 (мониторинг 12.08)."""
    from pathlib import Path

    notes: list[str] = []
    app_ok = re.compile(r"^(?:JPEG|IMG|DSC)[_\-]?\d{8}[_\-]?\d{6}", re.I)
    for ph in photos or []:
        fn = str(ph.get("filename") or ph.get("name") or "").strip()
        if not fn:
            continue
        base = Path(fn).name
        stem = Path(base).stem
        low = base.lower()
        if low.endswith(".png"):
            notes.append(f"возможный скрин ({base}): png — проверить")
        elif not app_ok.match(stem):
            notes.append(f"имя файла не по шаблону JPEG_… ({base}) — проверить")
    seen: set[str] = set()
    out: list[str] = []
    for n in notes:
        if n not in seen:
            seen.add(n)
            out.append(n)
    return out[:8]


def shot_span_seconds(photos: list[dict[str, Any]] | None) -> float | None:
    """Seconds between earliest and latest filename timestamps; None if <2 times."""
    from photo_meta import shot_datetime_from_filename

    times = []
    for ph in photos or []:
        dt = shot_datetime_from_filename(str(ph.get("filename") or ""))
        if dt is not None:
            times.append(dt)
    if len(times) < 2:
        return None
    return (max(times) - min(times)).total_seconds()


def apply_razryv(
    checklist: str,
    answers: dict[str, Any] | None,
    *,
    span_sec: float | None,
    comment: str = "",
) -> VerdictResult | None:
    """РАЗРЫВ: gap <20s and result-of-work not shown → violation marker (12.08)."""
    if span_sec is None or span_sec >= 20:
        return None
    a = normalize_answers(answers or {})
    cl = (checklist or "").strip()
    trigger = False
    if cl == "1а" and a.get("А3") == 0:
        trigger = True
    elif cl == "1б" and a.get("С1") == 1 and a.get("С2") == 0:
        trigger = True
    elif cl == "1г" and a.get("Б1") == 1 and a.get("Б2") == 0:
        trigger = True
    if not trigger:
        return None
    return VerdictResult(
        photo_verdict=VERDICT_VIOLATION,
        za_chto=_za("РАЗРЫВ"),
        pometki=f"интервал кадров {span_sec:.0f}с < 20с при непоказанном результате",
        comment=comment or "разрыв: одно состояние снято дважды",
    )

def normalize_answers(raw: Any) -> dict[str, int]:
    """Flatten model answers to {code: int}."""
    out: dict[str, int] = {}
    if not isinstance(raw, dict):
        return out
    for k, v in raw.items():
        code = str(k).strip()
        code = _CODE_TRANS.get(code, _CODE_TRANS.get(code.upper(), code))
        n = _as_int(v)
        if n is not None:
            out[code] = n
    return out


def _za(*codes: str) -> str:
    parts = [f"фото:{c}" for c in codes if c]
    return "; ".join(parts)


def compute_photo_verdict(
    checklist: str,
    answers: dict[str, Any] | None,
    *,
    comment: str = "",
) -> VerdictResult:
    """TZ §6.5: program computes verdict from 0/1 answers. First matching rule wins."""
    a = normalize_answers(answers or {})
    cl = (checklist or "").strip()
    comment = (comment or "").strip()

    if cl == "1а":
        return _verdict_1a(a, comment)
    if cl == "1б":
        return _verdict_1b(a, comment)
    if cl == "1в":
        return _verdict_1v(a, comment)
    if cl == "1г":
        return _verdict_1g(a, comment)
    if cl == "2":
        return _verdict_2(a, comment)
    return VerdictResult(
        photo_verdict=VERDICT_VIOLATION,
        za_chto="фото:unknown_checklist",
        pometki="",
        comment=comment or f"unknown checklist {cl}",
    )


def _verdict_1a(a: dict[str, int], comment: str) -> VerdictResult:
    """Appendix B 1а. А5 учитывается только при А2=1 и А3=1 (иначе 0 = неприменимо, не провал)."""
    pometki: list[str] = []
    if a.get("О3") == 1:
        return VerdictResult(VERDICT_VIOLATION, _za("О3"), "", comment or "подделка")
    if a.get("А0") == 0:
        # А1–А6 не учитываются
        return VerdictResult(
            VERDICT_TYPE_MISMATCH, _za("А0"), "ошибка разметки типа точки", comment or "не уличная КП"
        )
    fails: list[str] = []
    if a.get("О1") == 0:
        fails.append("О1")
    if a.get("О2") == 0:
        fails.append("О2")
    if a.get("А1") == 0:
        fails.append("А1")
    if a.get("А4") == 1:
        fails.append("А4")
    if fails:
        return VerdictResult(VERDICT_VIOLATION, _za(*fails), "", comment or f"провал {','.join(fails)}")

    a2, a3, a5 = a.get("А2"), a.get("А3"), a.get("А5")
    if a2 == 1 and a3 == 1:
        # только здесь А5=0 — хронология; А5=0 при других ветках = неприменимо
        if a5 == 0:
            return VerdictResult(VERDICT_VIOLATION, _za("А5"), "", comment or "пустые раньше полных")
        if "А6" in a:
            pometki.append(f"баков на фото: {a['А6']}")
        return VerdictResult(VERDICT_CONFIRMED, "", "; ".join(pometki), comment)
    if a2 == 1 and a3 == 0:
        return VerdictResult(VERDICT_VIOLATION, _za("А3"), "", comment or "вывоз не показан")
    if a2 == 0 and a3 == 0:
        return VerdictResult(VERDICT_VIOLATION, _za("А2", "А3"), "", comment or "состояние баков не показано")
    if a2 == 0 and a3 == 1:
        pometki.append("наполнение по фото не зафиксировано (пусто или ниже кромки)")
        if "А6" in a:
            pometki.append(f"баков на фото: {a['А6']}")
        return VerdictResult(VERDICT_CONFIRMED, "", "; ".join(pometki), comment)
    return VerdictResult(VERDICT_CONFIRMED, "", "; ".join(pometki), comment)


def _verdict_1b(a: dict[str, int], comment: str) -> VerdictResult:
    """Appendix B 1б: branch on С1 — zero on С2–С4 may mean «неприменимо», not fail."""
    pometki: list[str] = []
    if a.get("О3") == 1:
        return VerdictResult(VERDICT_VIOLATION, _za("О3"), "", comment or "подделка")
    if a.get("О1") == 0:
        return VerdictResult(VERDICT_VIOLATION, _za("О1"), "", comment or "материала недостаточно")
    if a.get("О2") == 0:
        return VerdictResult(VERDICT_VIOLATION, _za("О2"), "", comment or "не то место")

    c1 = a.get("С1")
    c6 = a.get("С6")  # missing ≡ 0 for branching when С1=0
    # Пустая сигнальная точка: С1=0 → С2–С4 не читаем (нули = неприменимо, не провал)
    if c1 == 0:
        if c6 == 1:
            return VerdictResult(
                VERDICT_VIOLATION, _za("С6"), "", comment or "закрытая мусорокамера, ёмкости не выкачены"
            )
        pometki.append("накопление ТБО по фото не зафиксировано")
        if a.get("С5") == 1:
            pometki.append("на точке остался бытовой мусор — проверить")
        return VerdictResult(VERDICT_CONFIRMED, "", "; ".join(pometki), comment)

    if c1 == 1:
        # С2–С4 учитываются только здесь
        if a.get("С2") == 0:
            return VerdictResult(VERDICT_VIOLATION, _za("С2"), "", comment or "вывоз не показан")
        fails = []
        if a.get("С3") == 0:
            fails.append("С3")
        if a.get("С4") == 0:
            fails.append("С4")
        if fails:
            return VerdictResult(VERDICT_VIOLATION, _za(*fails), "", comment or f"провал {','.join(fails)}")

    if a.get("С5") == 1:
        pometki.append("на точке остался бытовой мусор — проверить")
    return VerdictResult(VERDICT_CONFIRMED, "", "; ".join(pometki), comment)


def _verdict_1v(a: dict[str, int], comment: str) -> VerdictResult:
    if a.get("О3") == 1:
        return VerdictResult(VERDICT_VIOLATION, _za("О3"), "", comment or "подделка")
    if a.get("О1") == 0:
        return VerdictResult(VERDICT_VIOLATION, _za("О1"), "", comment or "материала недостаточно")
    if a.get("О2") == 0:
        return VerdictResult(VERDICT_VIOLATION, _za("О2"), "", comment or "не то место")
    if a.get("Р1") == 0:
        return VerdictResult(
            VERDICT_TYPE_MISMATCH,
            _za("Р1"),
            "проверить тип отходов / разметку площадки",
            comment or "контейнер РСО не опознан",
        )
    return VerdictResult(
        VERDICT_CONFIRMED,
        "",
        "наполнение РСО по фото не проверяется (контейнер закрыт)",
        comment,
    )


def _verdict_1g(a: dict[str, int], comment: str) -> VerdictResult:
    """Appendix B 1г: Б1=0 → Б2–Б4 не читаем (нули = неприменимо).

    TZ 04.08.2026: if Б2=0 and Б5=1 — contradiction (not a B2 violation):
    treat B2 as 1, continue with B3/B4, mark «спорные ответы Б2/Б5 — проверить».
    """
    pometki: list[str] = []
    if a.get("О3") == 1:
        return VerdictResult(VERDICT_VIOLATION, _za("О3"), "", comment or "подделка")
    if a.get("О1") == 0:
        return VerdictResult(VERDICT_VIOLATION, _za("О1"), "", comment or "материала недостаточно")
    if a.get("О2") == 0:
        return VerdictResult(VERDICT_VIOLATION, _za("О2"), "", comment or "не то место")

    if a.get("Б1") == 0:
        # Б2–Б4 не учитываются
        pometki.append("крупногабарит по фото не зафиксирован")
        if a.get("Б5") == 1:
            pometki.append("на площадке осталась посторонняя свалка (не КГО) — передать")
        return VerdictResult(VERDICT_CONFIRMED, "", "; ".join(pometki), comment)

    if a.get("Б1") == 1:
        b2 = a.get("Б2")
        if b2 == 0 and a.get("Б5") == 1:
            # contradiction: B5 says leftover is NOT KGO → cannot fail on «KGO not removed»
            b2 = 1
            pometki.append("спорные ответы Б2/Б5 — проверить")
        if b2 == 0:
            return VerdictResult(VERDICT_VIOLATION, _za("Б2"), "", comment or "крупногабарит не вывезен")
        fails = []
        if a.get("Б3") == 0:
            fails.append("Б3")
        if a.get("Б4") == 0:
            fails.append("Б4")
        if fails:
            vr = VerdictResult(VERDICT_VIOLATION, _za(*fails), "; ".join(pometki), comment or f"провал {','.join(fails)}")
            if a.get("Б5") == 1 and "спорные" not in "; ".join(pometki):
                extra = "на площадке осталась посторонняя свалка (не КГО) — передать"
                vr.pometki = "; ".join(x for x in (vr.pometki, extra) if x)
            return vr

    if a.get("Б5") == 1 and "спорные ответы Б2/Б5" not in "; ".join(pometki):
        pometki.append("на площадке осталась посторонняя свалка (не КГО) — передать")
    return VerdictResult(VERDICT_CONFIRMED, "", "; ".join(pometki), comment)


_BLIND_COMMENT_RE = re.compile(
    r"нет\s+(информации|изображен|данных|фото|кадр)|"
    r"no\s+(image|photo|data|information)|"
    r"unable\s+to\s+(see|analyze|assess)|"
    r"cannot\s+(see|analyze|assess)",
    re.IGNORECASE,
)


def is_vision_blind(
    *,
    status: str | None = None,
    answers: dict[str, Any] | None = None,
    comment: str = "",
) -> bool:
    """Model did not actually inspect frames → human, not violation (errors doc §3)."""
    st = (status or "").strip().lower()
    if st in {"no_photos", "vision_error", "blind"}:
        return True
    a = normalize_answers(answers or {})
    if not a:
        return True
    if all(v == 0 for v in a.values()) and _BLIND_COMMENT_RE.search(comment or ""):
        return True
    return False


def _verdict_2(a: dict[str, int], comment: str) -> VerdictResult:
    """Appendix B 2: Н5 for «нет бака» is N/A (model 0) — only Н5=1 is a fail."""
    pometki: list[str] = []
    if a.get("О3") == 1:
        return VerdictResult(VERDICT_VIOLATION, _za("О3"), "", comment or "подделка")
    if a.get("О1") == 0:
        return VerdictResult(VERDICT_VIOLATION, _za("О1"), "", comment or "материала недостаточно")
    if a.get("О2") == 0:
        return VerdictResult(VERDICT_VIOLATION, _za("О2"), "", comment or "кадры из разных мест")
    # Н5=0 may mean «неприменимо» (нет бака) — только 1 = провал
    if a.get("Н5") == 1:
        return VerdictResult(VERDICT_VIOLATION, _za("Н5"), "", comment or "проезд свободен вопреки причине")
    fails = []
    if a.get("Н1") == 0:
        fails.append("Н1")
    if a.get("Н2") == 0:
        fails.append("Н2")
    if a.get("Н3") == 0:
        fails.append("Н3")
    if fails:
        return VerdictResult(VERDICT_VIOLATION, _za(*fails), "", comment or "причина не подтверждена")

    if a.get("Н4") == 0:
        pometki.append("госномер не зафиксирован")
    if a.get("Н6") == 1:
        pometki.append("на точке осталось накопление")
    return VerdictResult(VERDICT_CONFIRMED, "", "; ".join(pometki), comment)
