"""Merge Stage-1 + Stage-2 into ИТОГ (TZ §7.2)."""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum


class PhotoVerdict(str, Enum):
    CONFIRMED = "ПОДТВЕРЖДЕНО"
    VIOLATION = "НАРУШЕНИЕ"
    TYPE_MISMATCH = "НЕСООТВЕТСТВИЕ ТИПА"
    MISSING = ""


class Itog(str, Enum):
    CLEAN = "ЧИСТО"
    PHOTO = "НАРУШЕНИЕ (фото)"
    SCHEDULE = "НАРУШЕНИЕ (график)"
    HUMAN = "К ЧЕЛОВЕКУ"


@dataclass
class MergeInput:
    photo_verdict: PhotoVerdict
    geo_fail: bool
    geo_na_no_coords: bool  # no coords on any photo → place unchecked
    schedule_fail: bool  # ФОТО/ТРЕК/ВРЕМЯ/(ОТЧЁТ/ФОТО_ПРЕП)
    special_human: bool  # ручное закрытие, несостоявшаяся смена, Требуется уточнение, …


def merge_itog(inp: MergeInput) -> Itog:
    # TZ §7.2 top-down
    if inp.special_human or inp.photo_verdict == PhotoVerdict.TYPE_MISMATCH or inp.geo_na_no_coords:
        # exception: type mismatch + math fail → schedule/geo label, type goes to notes
        if inp.photo_verdict == PhotoVerdict.TYPE_MISMATCH and (inp.geo_fail or inp.schedule_fail):
            return Itog.SCHEDULE
        return Itog.HUMAN
    # «(фото)» только при нарушении осмотра снимков; ГЕО/место → «(график)» (12.08).
    if inp.photo_verdict == PhotoVerdict.VIOLATION:
        return Itog.PHOTO
    if inp.geo_fail or inp.schedule_fail:
        return Itog.SCHEDULE
    return Itog.CLEAN
