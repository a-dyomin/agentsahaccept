from __future__ import annotations

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    s3_endpoint_url: str = "https://s3.ru-1.storage.selcloud.ru"
    s3_region: str = "ru-1"
    s3_bucket: str = "main"
    s3_access_key: str = ""
    s3_secret_key: str = ""
    s3_addressing_style: str = "path"

    greta_ssh_host: str = "greta.akea-ds.ru"
    greta_ssh_port: int = 34023
    greta_ssh_user: str = "gretaadmin"
    greta_ssh_key: str = "~/.ssh/greta2_migration_ed25519"

    wialon_base_url: str = "https://wialon.akea-ds.ru"
    wialon_token: str = ""

    photo_radius_m: float = 100
    track_radius_m: float = 200
    non_pickup_track_radius_m: float = 300
    photo_at_arrival_radius_m: float = 100
    time_tolerance_min: float = 7
    non_pickup_time_tolerance_min: float = 5
    track_search_window_min: float = 30


settings = Settings()
