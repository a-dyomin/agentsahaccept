"""Haversine distance and Stage-1 geo helpers (TZ §4.5 / §5)."""

from __future__ import annotations

import math
from typing import Iterable


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    r = 6_371_000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlmb = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dlmb / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def min_distance_m(
    site_lat: float,
    site_lon: float,
    points: Iterable[tuple[float, float]],
) -> float | None:
    dists = [haversine_m(site_lat, site_lon, lat, lon) for lat, lon in points]
    return min(dists) if dists else None
