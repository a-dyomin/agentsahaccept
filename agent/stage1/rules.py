"""Stage-1 rule engine stubs — coverage / completed / non-pickup (TZ §5)."""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Any


class Flag(str, Enum):
    OK = "1"
    FAIL = "0"
    NA = "Н/Д"


@dataclass
class CheckResult:
    code: str
    flag: Flag
    detail: dict[str, Any] = field(default_factory=dict)


def check_photo_completeness(photo_count: int, min_required: int = 2) -> CheckResult:
    flag = Flag.OK if photo_count >= min_required else Flag.FAIL
    return CheckResult(code="ФОТО", flag=flag, detail={"ФОТО_КОЛ": photo_count})


def check_geo(
    distances_m: list[float | None],
    radius_m: float,
) -> CheckResult:
    """Flag OK if at least one photo is within radius (TZ §5.2)."""
    known = [d for d in distances_m if d is not None]
    if not known and distances_m:
        # all missing coords
        return CheckResult(
            code="ГЕО",
            flag=Flag.NA,
            detail={"ГЕО_БЕЗ_КООРД": len(distances_m), "ГЕО_ВНЕ": 0},
        )
    if not distances_m:
        return CheckResult(code="ГЕО", flag=Flag.NA, detail={"ГЕО_БЕЗ_КООРД": 0, "ГЕО_ВНЕ": 0})

    min_m = min(known) if known else None
    outside = sum(1 for d in known if d > radius_m)
    without = sum(1 for d in distances_m if d is None)
    flag = Flag.OK if min_m is not None and min_m <= radius_m else Flag.FAIL
    if min_m is None:
        flag = Flag.NA
    return CheckResult(
        code="ГЕО",
        flag=flag,
        detail={"ГЕО_МИН_М": min_m, "ГЕО_ВНЕ": outside, "ГЕО_БЕЗ_КООРД": without},
    )


def check_track_arrival(
    arrival_m: float | None,
    radius_m: float,
    track_exists: bool,
) -> list[CheckResult]:
    track_exists_flag = Flag.OK if track_exists else Flag.FAIL
    results = [CheckResult(code="ТРЕК_ЕСТЬ", flag=track_exists_flag)]
    if not track_exists or arrival_m is None:
        results.append(CheckResult(code="ТРЕК", flag=Flag.NA, detail={"ТРЕК_М": None}))
    else:
        flag = Flag.OK if arrival_m <= radius_m else Flag.FAIL
        results.append(CheckResult(code="ТРЕК", flag=flag, detail={"ТРЕК_М": arrival_m}))
    return results
