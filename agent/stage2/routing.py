"""Checklist routing (TZ §6.2)."""

from __future__ import annotations

from enum import Enum


class Checklist(str, Enum):
    KP = "1а"
    SIGNAL = "1б"
    RSO = "1в"
    KGO = "1г"
    NON_PICKUP = "2"


def route_checklist(
    *,
    state: str,
    waste_type: str,
    site_type: str,
) -> Checklist | None:
    state_l = (state or "").strip().lower()
    waste = (waste_type or "").strip().upper()
    site = (site_type or "").strip().lower()

    if "отменена водителем" in state_l or state_l == "cancelled_by_driver":
        return Checklist.NON_PICKUP
    if waste in {"РСО", "RSO"}:
        return Checklist.RSO
    if waste in {"КГО", "KGO"}:
        return Checklist.KGO
    # Greta: «Сигнальный метод» (UI) / scheduled (DB enum). Второе значение — «Контейнерная площадка»/containers → 1а.
    if site in {"сигнальный метод", "scheduled"}:
        return Checklist.SIGNAL
    if "выполн" in state_l or state_l in {"done", "completed"}:
        return Checklist.KP
    return None
