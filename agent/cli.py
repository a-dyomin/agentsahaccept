from __future__ import annotations

import json
from pathlib import Path

import typer
from rich import print

from agent.config import settings

app = typer.Typer(add_completion=False, no_args_is_help=True)


@app.command("smoke-s3")
def smoke_s3_cmd(max_keys: int = 5) -> None:
    """Проверка доступа к Selectel S3."""
    if not settings.s3_access_key or not settings.s3_secret_key:
        print("[red]Заполните S3_ACCESS_KEY / S3_SECRET_KEY в .env[/red]")
        raise typer.Exit(1)
    from agent.ingest.s3_photos import smoke_s3

    result = smoke_s3(max_keys=max_keys)
    print(json.dumps(result, ensure_ascii=False, indent=2, default=str))


@app.command("run-day")
def run_day(
    date: str = typer.Option(..., help="YYYY-MM-DD"),
    stage1_only: bool = False,
    data_dir: Path = Path("data"),
) -> None:
    """Прогон дня (пока каркас: читает CSV из data/raw если есть)."""
    print(f"[cyan]run-day {date} stage1_only={stage1_only} data_dir={data_dir}[/cyan]")
    print("[yellow]Полный прогон Stage1/2 ещё в разработке — каркас готов.[/yellow]")


@app.command("info")
def info() -> None:
    print(
        {
            "s3_endpoint": settings.s3_endpoint_url,
            "s3_bucket": settings.s3_bucket,
            "greta_ssh": f"{settings.greta_ssh_user}@{settings.greta_ssh_host}:{settings.greta_ssh_port}",
            "photo_radius_m": settings.photo_radius_m,
            "track_radius_m": settings.track_radius_m,
        }
    )


def main() -> None:
    app()


if __name__ == "__main__":
    main()
