from __future__ import annotations

import boto3
from botocore.config import Config

from accept_agent.config import Settings


def s3_client(settings: Settings, *, verify: bool | None = None):
    verify_ssl = settings.s3_verify_ssl if verify is None else verify
    return boto3.client(
        "s3",
        endpoint_url=settings.s3_endpoint_url,
        region_name=settings.s3_region,
        aws_access_key_id=settings.s3_access_key,
        aws_secret_access_key=settings.s3_secret_key,
        verify=verify_ssl,
        config=Config(signature_version="s3v4", s3={"addressing_style": "path"}),
    )


def check_s3(settings: Settings) -> dict:
    verify_modes = [True, False] if settings.s3_verify_ssl else [False]

    last_error: Exception | None = None
    for verify in verify_modes:
        try:
            client = s3_client(settings, verify=verify)
            buckets = [b["Name"] for b in client.list_buckets().get("Buckets", [])]
            client.head_bucket(Bucket=settings.s3_bucket)
            resp = client.list_objects_v2(Bucket=settings.s3_bucket, MaxKeys=3)
            sample_keys = [o["Key"] for o in resp.get("Contents", [])]
            return {
                "ok": True,
                "buckets": buckets,
                "bucket": settings.s3_bucket,
                "head_ok": True,
                "sample_keys": sample_keys,
                "verify_ssl": verify,
            }
        except Exception as exc:  # noqa: BLE001
            last_error = exc
            continue
    return {"ok": False, "error": str(last_error)}
