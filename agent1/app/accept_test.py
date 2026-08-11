"""Acceptance checks vs TZ dump for 2026-07-12 (Данные из Гретты — что нужно агенту)."""
from __future__ import annotations

from typing import Any

from stage2 import Checklist, route_checklist_for_accept

# Gold numbers valid ONLY for this day (errors doc §5: other days are reference-only)
GOLD_DAY = "2026-07-12"

# Gold numbers are valid ONLY for this day (errors doc §5)
GOLD_DAY = "2026-07-12"

# Expected from repo doc for day 2026-07-12
EXPECTED_COUNTS = {
    "orders": 9193,
    "photos": 16094,
    "reports": 7703,
}

EXPECTED_CHECKLISTS = {
    Checklist.KP.value: 5704,  # 1а
    Checklist.SIGNAL.value: 1318,  # 1б
    Checklist.RSO.value: 121,  # 1в
    Checklist.KGO.value: 189,  # 1г
    Checklist.NON_PICKUP.value: 280,  # 2
}


def compare_counts(actual: dict[str, Any]) -> dict[str, Any]:
    checks = []
    ok = True
    for key, exp in EXPECTED_COUNTS.items():
        got = int(actual.get(key) or 0)
        match = got == exp
        ok = ok and match
        checks.append(
            {"metric": key, "expected": exp, "actual": got, "ok": match, "delta": got - exp}
        )
    return {"ok": ok, "checks": checks}


def checklist_breakdown(orders: list[dict[str, Any]], *, tol: int = 2) -> dict[str, Any]:
    tallies: dict[str, int] = {k: 0 for k in EXPECTED_CHECKLISTS}
    skipped = 0
    for o in orders:
        cl = route_checklist_for_accept(
            state=str(o.get("state") or ""),
            waste_type=str(o.get("waste_type_name") or ""),
            site_type=str(o.get("site_stype") or ""),
            photo_count=int(o.get("photo_count") or 0),
        )
        if cl is None:
            skipped += 1
            continue
        tallies[cl.value] = tallies.get(cl.value, 0) + 1

    checks = []
    ok = True
    for key, exp in EXPECTED_CHECKLISTS.items():
        got = tallies.get(key, 0)
        match = abs(got - exp) <= tol
        ok = ok and match
        checks.append(
            {
                "checklist": key,
                "expected": exp,
                "actual": got,
                "ok": match,
                "delta": got - exp,
            }
        )
    total = sum(tallies.values())
    expected_total = sum(EXPECTED_CHECKLISTS.values())
    return {
        "ok": ok and abs(total - expected_total) <= tol * 2,
        "checks": checks,
        "skipped": skipped,
        "stage2_total": total,
        "expected_stage2_total": expected_total,
        "tol": tol,
    }
