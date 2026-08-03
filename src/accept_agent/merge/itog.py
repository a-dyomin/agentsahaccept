from __future__ import annotations

"""Merge Stage1 + Stage2 into ИТОГ per TZ §7.2."""

from typing import Literal

Itog = Literal["К ЧЕЛОВЕКУ", "НАРУШЕНИЕ (фото)", "НАРУШЕНИЕ (график)", "ЧИСТО"]


def compute_itog(
    *,
    to_human: bool = False,
    photo_verdict: str | None = None,
    geo_fail: bool = False,
    schedule_fail: bool = False,
) -> Itog:
    if to_human or photo_verdict == "НЕСООТВЕТСТВИЕ ТИПА":
        return "К ЧЕЛОВЕКУ"
    if photo_verdict == "НАРУШЕНИЕ" or geo_fail:
        return "НАРУШЕНИЕ (фото)"
    if schedule_fail:
        return "НАРУШЕНИЕ (график)"
    return "ЧИСТО"
