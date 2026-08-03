from __future__ import annotations

import csv
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

import pandas as pd


def read_csv(path: Path, **kwargs: Any) -> pd.DataFrame:
    """Try UTF-8 first (Greta admin dumps), then cp1251."""
    last_err: Exception | None = None
    for enc in ("utf-8-sig", "utf-8", "cp1251"):
        try:
            return pd.read_csv(path, encoding=enc, low_memory=False, **kwargs)
        except UnicodeDecodeError as exc:
            last_err = exc
            continue
    raise UnicodeDecodeError(
        "unknown", b"", 0, 1, f"Cannot decode {path}: {last_err}"
    )


def find_export(data_dir: Path, prefix: str) -> Path:
    matches = sorted(data_dir.glob(f"{prefix}*.csv"))
    if not matches:
        # also allow exact names without date suffix
        exact = data_dir / f"{prefix}.csv"
        if exact.exists():
            return exact
        raise FileNotFoundError(f"No CSV matching {prefix}*.csv in {data_dir}")
    return matches[-1]


@dataclass
class DayExports:
    orders: pd.DataFrame
    sites_by_order: pd.DataFrame
    photos: pd.DataFrame
    reports: pd.DataFrame
    fail_reasons: pd.DataFrame | None = None


def load_day_exports(data_dir: Path) -> DayExports:
    """Load Greta admin CSV dumps (same shape as TZ folder «Выгрузки Гретты»)."""
    data_dir = Path(data_dir)
    orders = read_csv(find_export(data_dir, "order_"))
    photos = read_csv(find_export(data_dir, "photo_"))
    reports = read_csv(find_export(data_dir, "report_site_"))
    sites = read_csv(data_dir / "orders_12.07.26.csv") if (data_dir / "orders_12.07.26.csv").exists() else read_csv(
        find_export(data_dir, "orders_")
    )
    fail_path = list(data_dir.glob("fail_reason_*.csv"))
    fail = read_csv(fail_path[0]) if fail_path else None
    return DayExports(
        orders=orders,
        sites_by_order=sites,
        photos=photos,
        reports=reports,
        fail_reasons=fail,
    )


def parse_coords(value: Any) -> tuple[float, float] | None:
    if value is None or (isinstance(value, float) and pd.isna(value)):
        return None
    s = str(value).strip().replace(";", ",")
    if not s or s.lower() in {"nan", "none", "null"}:
        return None
    parts = [p.strip() for p in s.replace(" ", ",").split(",") if p.strip()]
    if len(parts) < 2:
        # try space-separated "lat lon"
        parts = s.split()
    if len(parts) < 2:
        return None
    try:
        a, b = float(parts[0]), float(parts[1])
    except ValueError:
        return None
    # Greta dumps usually lat,lon; if |a|>90 assume lon,lat
    if abs(a) <= 90 and abs(b) <= 180:
        return a, b
    if abs(b) <= 90 and abs(a) <= 180:
        return b, a
    return None
