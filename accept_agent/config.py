from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    s3_endpoint_url: str = "https://s3.ru-1.storage.selcloud.ru"
    s3_region: str = "ru-1"
    s3_bucket: str = "main"
    s3_access_key: str = ""
    s3_secret_key: str = ""
    s3_verify_ssl: bool = True

    greta_ssh_host: str = "greta.akea-ds.ru"
    greta_ssh_port: int = 34023
    greta_ssh_user: str = "gretaadmin"
    greta_ssh_key: str = "~/.ssh/greta2_migration_ed25519"

    photo_radius_m: float = 100
    track_radius_m: float = 200
    no_pickup_track_radius_m: float = 300
    photo_near_arrival_m: float = 100
    time_tolerance_min: float = 7
    no_pickup_time_tolerance_min: float = 5
    track_search_window_min: float = 30

    data_dir: Path = Field(default=Path("data/greta_exports"))
    output_dir: Path = Field(default=Path("outputs"))


@lru_cache
def get_settings() -> Settings:
    return Settings()
