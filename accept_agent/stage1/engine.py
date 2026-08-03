from __future__ import annotations

from dataclasses import dataclass, asdict
from typing import Any

import pandas as pd

from accept_agent.config import Settings
from accept_agent.geo import haversine_m
from accept_agent.ingest.csv_loader import DayExports, parse_coords


# Order states as in Greta admin CSV (Russian labels)
STATE_DONE = "Выполнено"
STATE_NEW = "Новая"
STATE_CANCEL_DRIVER = "Отменена водителем"
STATE_CANCEL_DISPATCHER = "Отменена диспетчером"
STATE_CANCEL_CONSUMER = "Отменено потребителем"


@dataclass
class CoverageRow:
    day: str
    order_id: int
    site_id: Any
    coords: str
    address: str
    client: str
    provider: str
    site_type: str
    waste_type: str
    state: str
    schedule_id: Any
    create_type: str
    transfer: str
    reason: str


def _col(df: pd.DataFrame, *names: str) -> str:
    for n in names:
        if n in df.columns:
            return n
    raise KeyError(f"None of columns {names} in {list(df.columns)[:20]}")


def not_in_work(exports: DayExports) -> pd.DataFrame:
    """Таблица А — заявки, не взятые в работу (ТЗ 5.1 / 8.1)."""
    o = exports.orders
    sites = exports.sites_by_order
    id_col = _col(o, "#")
    state_col = _col(o, "Состояние заявки")
    sched_col = _col(o, "# [Смена]")
    day_col = _col(o, "День вывоза")
    site_col = _col(o, "# [Площадка]")
    provider_col = _col(o, "Наименование [Перевозчик]")
    waste_col = _col(o, "Наименование [Тип отходов]")
    create_col = _col(o, "Тип создания")
    transfer_col = _col(o, "Перенесена из другой смены")

    state = o[state_col].fillna("").astype(str).str.strip()
    sched = o[sched_col]
    empty_sched = sched.isna() | (sched.astype(str).str.strip() == "")
    empty_state = state.eq("") | state.eq("nan")

    mask = (
        empty_sched
        | state.eq(STATE_NEW)
        | empty_state
        | state.eq(STATE_CANCEL_DISPATCHER)
    )
    # consumer cancel — exclude
    mask &= ~state.eq(STATE_CANCEL_CONSUMER)

    sub = o.loc[mask].copy()
    site_id_col = _col(sites, "№ площадки")
    order_id_col = _col(sites, "№ заявки")
    sites_idx = sites.set_index(order_id_col, drop=False)

    rows: list[dict[str, Any]] = []
    for _, r in sub.iterrows():
        oid = int(r[id_col])
        s = sites_idx.loc[oid] if oid in sites_idx.index else None
        if s is not None and isinstance(s, pd.DataFrame):
            s = s.iloc[0]
        reason_parts = []
        if pd.isna(r[sched_col]) or str(r[sched_col]).strip() == "":
            reason_parts.append("без смены")
        st = str(r[state_col]).strip() if pd.notna(r[state_col]) else ""
        if st == STATE_NEW or st == "":
            reason_parts.append(st or "пустое состояние")
        if st == STATE_CANCEL_DISPATCHER:
            reason_parts.append(STATE_CANCEL_DISPATCHER)
        rows.append(
            {
                "День вывоза": r[day_col],
                "№ заявки": oid,
                "№ площадки": None if s is None else s.get(site_id_col, r[site_col]),
                "Координаты": None if s is None else s.get("Координаты"),
                "Адрес": None if s is None else s.get("Адрес"),
                "Клиент": None if s is None else s.get("Наименование"),
                "Перевозчик": r[provider_col],
                "Тип площадки": None if s is None else s.get("Тип"),
                "Тип отходов": r[waste_col],
                "Состояние заявки": st,
                "№ смены": r[sched_col],
                "Тип создания": r[create_col],
                "Перенос": r[transfer_col],
                "Причина отбора": "; ".join(reason_parts),
            }
        )
    return pd.DataFrame(rows)


def check_completed(exports: DayExports, settings: Settings) -> pd.DataFrame:
    """Таблица Б — выполненные: ФОТО (+ ГЕО если есть координаты фото; иначе Н/Д)."""
    o = exports.orders
    photos = exports.photos
    sites = exports.sites_by_order

    id_col = _col(o, "#")
    state_col = _col(o, "Состояние заявки")
    day_col = _col(o, "День вывоза")
    sched_col = _col(o, "# [Смена]")
    site_ref = _col(o, "# [Площадка]")

    done = o[o[state_col].astype(str).str.strip().eq(STATE_DONE)].copy()
    photo_order_col = _col(photos, "# [Заявка]")
    photo_counts = photos.groupby(photo_order_col).size().rename("ФОТО_КОЛ")

    sites_idx = sites.set_index(_col(sites, "№ заявки"), drop=False)

    # optional photo coords column if present in future dumps
    has_photo_coords = "Координаты" in photos.columns

    rows: list[dict[str, Any]] = []
    for _, r in done.iterrows():
        oid = int(r[id_col])
        n_photos = int(photo_counts.get(oid, 0))
        foto_flag: Any = 1 if n_photos >= 2 else 0

        site_lat = site_lon = None
        address = ""
        if oid in sites_idx.index:
            s = sites_idx.loc[oid]
            if isinstance(s, pd.DataFrame):
                s = s.iloc[0]
            address = str(s.get("Адрес", "") or "")
            coords = parse_coords(s.get("Координаты"))
            if coords:
                site_lat, site_lon = coords

        geo_flag: Any = "Н/Д"
        geo_min = None
        geo_out = None
        geo_no = None
        if has_photo_coords and site_lat is not None:
            ph = photos[photos[photo_order_col] == oid]
            dists = []
            no_coord = 0
            for _, p in ph.iterrows():
                pc = parse_coords(p.get("Координаты"))
                if not pc:
                    no_coord += 1
                    continue
                dists.append(haversine_m(site_lat, site_lon, pc[0], pc[1]))
            if dists:
                geo_min = round(min(dists), 1)
                geo_out = sum(1 for d in dists if d > settings.photo_radius_m)
                geo_flag = 1 if geo_min <= settings.photo_radius_m else 0
                geo_no = no_coord
            elif no_coord:
                geo_flag = "Н/Д"
                geo_no = no_coord

        rows.append(
            {
                "Дата": r[day_col],
                "№ смены": r[sched_col],
                "№ площадки": r[site_ref],
                "№ заявки": oid,
                "Адрес": address,
                "ТРЕК_ЕСТЬ": "Н/Д",
                "ФОТО": foto_flag,
                "ФОТО_КОЛ": n_photos,
                "ГЕО": geo_flag,
                "ГЕО_МИН_М": geo_min,
                "ГЕО_ВНЕ": geo_out,
                "ГЕО_БЕЗ_КООРД": geo_no,
                "ТРЕК": "Н/Д",
                "ТРЕК_М": None,
                "ВРЕМЯ": "Н/Д",
                "ВРЕМЯ_МИН": None,
                "ЧЕК-ЛИСТ": None,
                "ФОТО_ВЕРДИКТ": None,
                "ФОТО_ЗА_ЧТО": None,
                "ФОТО_ПОМЕТКИ": None,
                "ФОТО_КОММ": None,
                "ИТОГ": None,
                "ЗА_ЧТО": None,
                "ПОМЕТКИ": "трек/гео из CSV недоступны — нужен Greta DB/S3 EXIF"
                if geo_flag == "Н/Д"
                else "",
            }
        )
    return pd.DataFrame(rows)


def run_stage1(exports: DayExports, settings: Settings) -> dict[str, pd.DataFrame]:
    return {
        "not_in_work": not_in_work(exports),
        "completed": check_completed(exports, settings),
    }
