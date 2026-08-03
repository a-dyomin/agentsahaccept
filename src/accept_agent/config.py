from __future__ import annotations

from pathlib import Path

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
    # Set false behind SSL-inspecting proxies (corporate MITM).
    s3_verify_ssl: bool = True

    greta_ssh_host: str = "greta.akea-ds.ru"
    greta_ssh_port: int = 34023
    greta_ssh_user: str = "gretaadmin"
    greta_ssh_key_path: str = "~/.ssh/greta2_migration_ed25519"

    greta_database_url: str | None = None

    photo_radius_m: float = 100
    track_radius_m: float = 200
    track_radius_no_pickup_m: float = 300
    time_tolerance_min: float = 7
    time_tolerance_no_pickup_min: float = 5
    track_search_window_min: float = 30

    data_dir: Path = Path("data")

    @property
    def ssh_key_path(self) -> Path:
        return Path(self.greta_ssh_key_path).expanduser()


def get_settings() -> Settings:
    return Settings()
