"""Merge Stage-1 + Stage-2 into ИТОГ (TZ §7.2)."""
from __future__ import annotations

from dataclasses import dataclass
from enum import Enum


class PhotoVerdict(str, Enum):
    CONFIRMED = "ПОДТВЕРЖДЕНО"
    VIOLATION = "НАРУШЕНИЕ"
    TYPE_MISMATCH = "НЕСООТВЕТСТВИЕ ТИПА"
    SKIPPED = "ПРОПУСК"
    PENDING = "ОЖИДАЕТ"
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
    geo_na_no_coords: bool
    schedule_fail: bool
    special_human: bool


def merge_itog(inp: MergeInput) -> Itog:
    # TZ §7.2 top-down
    if inp.special_human or inp.photo_verdict == PhotoVerdict.TYPE_MISMATCH or inp.geo_na_no_coords:
        if inp.photo_verdict == PhotoVerdict.TYPE_MISMATCH and (inp.geo_fail or inp.schedule_fail):
            if inp.geo_fail:
                return Itog.PHOTO
            return Itog.SCHEDULE
        return Itog.HUMAN
    if inp.photo_verdict == PhotoVerdict.VIOLATION or inp.geo_fail:
        return Itog.PHOTO
    if inp.schedule_fail:
        return Itog.SCHEDULE
    # SKIPPED/PENDING: Stage1-only path (vision not run) → schedule/geo already applied above
    return Itog.CLEAN


def coerce_photo_verdict(v: str | None) -> PhotoVerdict:
    if not v:
        return PhotoVerdict.SKIPPED
    for item in PhotoVerdict:
        if item.value == v:
            return item
    return PhotoVerdict.PENDING
