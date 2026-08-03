from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

import click

from accept_agent.config import get_settings
from accept_agent.ingest.csv_loader import load_day_exports
from accept_agent.ingest.s3 import check_s3
from accept_agent.stage1 import run_stage1


@click.group()
def main() -> None:
    """Агент акцепта вывоза — теневой конвейер."""


@main.command("check-s3")
def check_s3_cmd() -> None:
    settings = get_settings()
    if not settings.s3_access_key or not settings.s3_secret_key:
        raise click.ClickException("Заполните S3_ACCESS_KEY / S3_SECRET_KEY в .env")
    result = check_s3(settings)
    if not result.get("ok"):
        raise click.ClickException(str(result))
    click.echo(f"OK buckets={result['buckets']} sample={result['sample_keys']}")


@main.command("stage1")
@click.option("--day", default="2026-07-12", show_default=True)
@click.option("--data-dir", type=click.Path(path_type=Path), default=None)
@click.option("--out-dir", type=click.Path(path_type=Path), default=None)
def stage1_cmd(day: str, data_dir: Path | None, out_dir: Path | None) -> None:
    settings = get_settings()
    data = Path(data_dir or settings.data_dir)
    out = Path(out_dir or settings.output_dir) / day / "stage1"
    out.mkdir(parents=True, exist_ok=True)

    click.echo(f"Loading exports from {data} ...")
    exports = load_day_exports(data)
    click.echo(
        f"orders={len(exports.orders)} photos={len(exports.photos)} "
        f"reports={len(exports.reports)} sites={len(exports.sites_by_order)}"
    )
    tables = run_stage1(exports, settings)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    for name, df in tables.items():
        path = out / f"{name}_{stamp}.csv"
        df.to_csv(path, index=False, encoding="utf-8-sig")
        click.echo(f"wrote {path} rows={len(df)}")


if __name__ == "__main__":
    main()
