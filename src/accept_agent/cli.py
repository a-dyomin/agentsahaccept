from __future__ import annotations

import json
from pathlib import Path

import typer
from rich import print

from accept_agent.config import get_settings
from accept_agent.ingest.greta_ssh import smoke_greta
from accept_agent.ingest.s3_photos import smoke_s3
from accept_agent.merge.itog import compute_itog
from accept_agent.stage2.routing import route_checklist

app = typer.Typer(add_completion=False, no_args_is_help=True)


@app.command()
def smoke() -> None:
    """Check S3 + Greta SSH connectivity using .env."""
    settings = get_settings()
    results = {
        "s3": smoke_s3(settings),
        "greta_ssh": smoke_greta(settings),
        "routing_sample": route_checklist(
            state="Выполнено", waste_type="ТБО", site_type="Контейнерная площадка"
        ),
        "itog_sample": compute_itog(photo_verdict="ПОДТВЕРЖДЕНО"),
    }
    print(json.dumps(results, ensure_ascii=False, indent=2))
    if not results["s3"]["ok"] or not results["greta_ssh"]["ok"]:
        raise typer.Exit(code=1)


@app.command()
def init_dirs() -> None:
    """Create local data folders."""
    root = get_settings().data_dir
    for name in ("raw", "cache", "out", "cache/photos"):
        Path(root / name).mkdir(parents=True, exist_ok=True)
    print(f"ready: {root.resolve()}")


if __name__ == "__main__":
    app()
