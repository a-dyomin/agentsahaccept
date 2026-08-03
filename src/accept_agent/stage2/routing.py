from __future__ import annotations

"""Stage 2 photo checklist routing + vision — stub."""

CHECKLIST_ORDER = ("2", "1v", "1g", "1b", "1a")


def route_checklist(*, state: str, waste_type: str, site_type: str) -> str | None:
    """Return checklist id per TZ §6.2, or None if not sent to vision."""
    if state == "Отменена водителем":
        return "2"
    if waste_type == "РСО":
        return "1v"
    if waste_type == "КГО":
        return "1g"
    if site_type == "Сигнальный метод":
        return "1b"
    if state == "Выполнено":
        return "1a"
    return None
