#!/usr/bin/env python3
"""Seed a small shadow run from Greta CSV exports (if present) or demo orders."""
from __future__ import annotations

import csv
import json
import os
import sys
from pathlib import Path

import httpx

API = os.environ.get("AGENT1_API", "http://127.0.0.1:8101").rstrip("/")
DAY = os.environ.get("AGENT1_DAY", "2026-07-12")
LIMIT = int(os.environ.get("AGENT1_SEED_LIMIT", "50"))


def load_from_csv(data_dir: Path) -> list[dict]:
    order_files = sorted(data_dir.glob("order_*.csv"))
    photo_files = sorted(data_dir.glob("photo_*.csv"))
    report_files = sorted(data_dir.glob("report_site_*.csv"))
    if not order_files:
        return []
    # detect encoding
    def read(path: Path):
        for enc in ("utf-8-sig", "utf-8", "cp1251"):
            try:
                with path.open("r", encoding=enc, newline="") as f:
                    return list(csv.DictReader(f))
            except UnicodeDecodeError:
                continue
        raise RuntimeError(path)

    orders = read(order_files[-1])
    photos = read(photo_files[-1]) if photo_files else []
    reports = read(report_files[-1]) if report_files else []
    photo_counts: dict[str, int] = {}
    for p in photos:
        oid = str(p.get("# [Заявка]") or "").strip()
        if oid:
            photo_counts[oid] = photo_counts.get(oid, 0) + 1
    report_orders = {
        str(r.get("# [Заявка]") or "").strip()
        for r in reports
        if str(r.get("# [Заявка]") or "").strip()
    }

    out = []
    for o in orders:
        oid = str(o.get("#") or "").strip()
        if not oid:
            continue
        state = str(o.get("Состояние заявки") or "").strip()
        human = str(o.get("Акцепт нарушения") or "").strip()
        out.append(
            {
                "order_id": int(oid),
                "kind": "stage1",
                "state": state,
                "schedule_id": o.get("# [Смена]") or None,
                "photo_count": photo_counts.get(oid, 0),
                "has_report": oid in report_orders,
                "human_verdict": human,
            }
        )
        if len(out) >= LIMIT:
            break
    return out


def demo_orders() -> list[dict]:
    return [
        {"order_id": 19000001, "kind": "stage1", "state": "Выполнено", "schedule_id": 1, "photo_count": 2, "has_report": True, "human_verdict": ""},
        {"order_id": 19000002, "kind": "stage1", "state": "Выполнено", "schedule_id": 1, "photo_count": 0, "has_report": True, "human_verdict": "Отменено РО (график)"},
        {"order_id": 19000003, "kind": "stage1", "state": "Новая", "schedule_id": None, "photo_count": 0, "has_report": False, "human_verdict": ""},
        {"order_id": 19000004, "kind": "stage1", "state": "Отменена водителем", "schedule_id": 2, "photo_count": 1, "has_report": True, "human_verdict": "Не нарушение"},
        {"order_id": 19000005, "kind": "stage1", "state": "Отменена водителем", "schedule_id": 2, "photo_count": 0, "has_report": False, "human_verdict": "Отменено РО (график)"},
    ]


def main() -> int:
    data_dir = Path(os.environ.get("AGENT1_DATA_CSV", str(Path.home() / "agent1" / "seed_csv")))
    orders = load_from_csv(data_dir) if data_dir.exists() else []
    if not orders:
        orders = demo_orders()
        print("using demo orders", len(orders))
    else:
        print("using csv orders", len(orders), "from", data_dir)
    with httpx.Client(timeout=60.0) as client:
        r = client.post(f"{API}/api/runs", json={"day": DAY, "orders": orders, "note": "shadow seed"})
        print(r.status_code, r.text)
        r.raise_for_status()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
