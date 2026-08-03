from __future__ import annotations

import boto3
from botocore.config import Config

from agent.config import settings


def s3_client():
    return boto3.client(
        "s3",
        endpoint_url=settings.s3_endpoint_url,
        region_name=settings.s3_region,
        aws_access_key_id=settings.s3_access_key,
        aws_secret_access_key=settings.s3_secret_key,
        config=Config(
            signature_version="s3v4",
            s3={"addressing_style": settings.s3_addressing_style},
        ),
    )


def smoke_s3(max_keys: int = 5) -> dict:
    client = s3_client()
    buckets = [b["Name"] for b in client.list_buckets().get("Buckets", [])]
    listed = client.list_objects_v2(Bucket=settings.s3_bucket, MaxKeys=max_keys)
    keys = [o["Key"] for o in listed.get("Contents", [])]
    sample_meta = []
    for key in keys[:3]:
        head = client.head_object(Bucket=settings.s3_bucket, Key=key)
        sample_meta.append(
            {
                "key": key,
                "content_type": head.get("ContentType"),
                "size": head.get("ContentLength"),
            }
        )
    return {
        "buckets": buckets,
        "bucket": settings.s3_bucket,
        "sample_keys": keys,
        "sample_meta": sample_meta,
    }
