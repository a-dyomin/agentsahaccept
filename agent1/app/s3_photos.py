"""Selectel S3 / public URL photo cache for Agent1 Stage2."""
from __future__ import annotations

import os
import ssl
from pathlib import Path
from urllib.request import Request, urlopen

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

S3_ENDPOINT = os.environ.get("S3_ENDPOINT_URL", "https://s3.ru-1.storage.selcloud.ru")
S3_REGION = os.environ.get("S3_REGION", "ru-1")
S3_BUCKET = os.environ.get("S3_BUCKET", "main")
S3_ACCESS_KEY = os.environ.get("S3_ACCESS_KEY", "")
S3_SECRET_KEY = os.environ.get("S3_SECRET_KEY", "")
S3_VERIFY_SSL = os.environ.get("S3_VERIFY_SSL", "true").lower() not in {"0", "false", "no"}
S3_ADDRESSING = os.environ.get("S3_ADDRESSING_STYLE", "path")
PHOTO_CACHE = Path(
    os.environ.get(
        "AGENT1_PHOTO_CACHE",
        str(Path.home() / "agent1" / "data" / "photos"),
    )
)


def s3_configured() -> bool:
    return bool(S3_ACCESS_KEY and S3_SECRET_KEY)


def public_url_for_key(blob_key: str) -> str:
    key = (blob_key or "").lstrip("/")
    return f"{S3_ENDPOINT.rstrip('/')}/{S3_BUCKET}/{key}"


def s3_client(*, verify: bool | None = None):
    if not s3_configured():
        raise RuntimeError("S3_ACCESS_KEY / S3_SECRET_KEY not set")
    v = S3_VERIFY_SSL if verify is None else verify
    return boto3.client(
        "s3",
        endpoint_url=S3_ENDPOINT,
        region_name=S3_REGION,
        aws_access_key_id=S3_ACCESS_KEY,
        aws_secret_access_key=S3_SECRET_KEY,
        verify=v,
        config=Config(signature_version="s3v4", s3={"addressing_style": S3_ADDRESSING}),
    )


def _client_with_fallback():
    """Try verify=True first when enabled; fall back to False (izhon/corporate TLS)."""
    modes = [True, False] if S3_VERIFY_SSL else [False]
    last: Exception | None = None
    for verify in modes:
        try:
            client = s3_client(verify=verify)
            client.head_bucket(Bucket=S3_BUCKET)
            return client
        except Exception as exc:  # noqa: BLE001
            last = exc
    raise RuntimeError(f"S3 unavailable: {last}")


def blob_key_candidates(blob_key: str) -> list[str]:
    """ActiveStorage keys may be stored raw or under variants prefix."""
    key = (blob_key or "").lstrip("/")
    if not key:
        return []
    out = [key]
    if "/" not in key and len(key) >= 3:
        out.append(f"{key[0:2]}/{key[2:4]}/{key}")
    return list(dict.fromkeys(out))


def _download_url(url: str, dest: Path) -> bool:
    req = Request(url, headers={"User-Agent": "agent1-photo-cache/1.0"})
    ctx = None if S3_VERIFY_SSL else ssl._create_unverified_context()  # noqa: SLF001
    with urlopen(req, timeout=60, context=ctx) as resp:  # noqa: S310
        data = resp.read()
    if not data:
        return False
    dest.write_bytes(data)
    return dest.exists() and dest.stat().st_size > 0


def cache_photo(
    blob_key: str | None = None,
    *,
    photo_id: int | None = None,
    day: str | None = None,
    photo_url: str | None = None,
) -> Path | None:
    """Download blob to local cache via public URL (preferred) or S3 API."""
    key = (blob_key or "").lstrip("/")
    url = (photo_url or "").strip() or (public_url_for_key(key) if key else "")
    if not key and not url:
        return None

    PHOTO_CACHE.mkdir(parents=True, exist_ok=True)
    day_dir = PHOTO_CACHE / (day or "_")
    day_dir.mkdir(parents=True, exist_ok=True)
    suffix = Path(key or url).suffix or ".jpg"
    name = f"{photo_id or 'x'}_{Path(key or url).name}"
    if not name.endswith(suffix):
        name = f"{name}{suffix}"
    dest = day_dir / name
    if dest.exists() and dest.stat().st_size > 0:
        return dest

    # 1) public HTTP — no auth, matches TZ note
    if url:
        try:
            if _download_url(url, dest):
                return dest
        except Exception:  # noqa: BLE001
            if dest.exists():
                dest.unlink(missing_ok=True)

    # 2) signed S3 API fallback
    if not key or not s3_configured():
        return None
    client = _client_with_fallback()
    last_err: Exception | None = None
    for cand in blob_key_candidates(key):
        try:
            client.download_file(S3_BUCKET, cand, str(dest))
            if dest.exists() and dest.stat().st_size > 0:
                return dest
        except ClientError as exc:
            last_err = exc
            continue
        except Exception as exc:  # noqa: BLE001
            last_err = exc
            continue
    if dest.exists():
        dest.unlink(missing_ok=True)
    if last_err:
        raise RuntimeError(f"S3 get failed for {key}: {last_err}")
    return None


def smoke_s3(max_keys: int = 3) -> dict:
    sample_keys: list[str] = []
    buckets: list[str] = []
    if s3_configured():
        client = _client_with_fallback()
        buckets = [b["Name"] for b in client.list_buckets().get("Buckets", [])]
        listed = client.list_objects_v2(Bucket=S3_BUCKET, MaxKeys=max_keys)
        sample_keys = [o["Key"] for o in listed.get("Contents", [])]
    public_ok = None
    if sample_keys:
        try:
            import urllib.request

            u = public_url_for_key(sample_keys[0])
            req = urllib.request.Request(u, method="HEAD")
            with urllib.request.urlopen(req, timeout=15) as resp:  # noqa: S310
                public_ok = resp.status
        except Exception as exc:  # noqa: BLE001
            public_ok = str(exc)[:200]
    return {
        "ok": True,
        "bucket": S3_BUCKET,
        "buckets": buckets,
        "sample_keys": sample_keys,
        "public_head": public_ok,
        "s3_api": s3_configured(),
    }
