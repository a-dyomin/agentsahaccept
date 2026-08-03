from __future__ import annotations

from botocore.config import Config
import boto3

from accept_agent.config import Settings


def s3_client(settings: Settings):
    if not settings.s3_access_key or not settings.s3_secret_key:
        raise RuntimeError("S3_ACCESS_KEY / S3_SECRET_KEY are not set")
    return boto3.client(
        "s3",
        endpoint_url=settings.s3_endpoint_url,
        region_name=settings.s3_region,
        aws_access_key_id=settings.s3_access_key,
        aws_secret_access_key=settings.s3_secret_key,
        verify=settings.s3_verify_ssl,
        config=Config(signature_version="s3v4", s3={"addressing_style": "path"}),
    )


def smoke_s3(settings: Settings) -> dict:
    client = s3_client(settings)
    head_ok = False
    try:
        client.head_bucket(Bucket=settings.s3_bucket)
        head_ok = True
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": f"head_bucket: {exc}"}
    listed = client.list_objects_v2(Bucket=settings.s3_bucket, MaxKeys=3)
    keys = [o["Key"] for o in listed.get("Contents", [])]
    sample_meta = None
    if keys:
        h = client.head_object(Bucket=settings.s3_bucket, Key=keys[0])
        sample_meta = {
            "key": keys[0],
            "content_type": h.get("ContentType"),
            "size": h.get("ContentLength"),
        }
    return {
        "ok": head_ok,
        "bucket": settings.s3_bucket,
        "sample_keys": keys,
        "sample_meta": sample_meta,
    }
