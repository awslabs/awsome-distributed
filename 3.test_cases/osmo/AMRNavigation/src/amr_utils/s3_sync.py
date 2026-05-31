"""Lightweight S3 upload/download helper for inter-stage data passing.

Uses boto3 to sync local directories to/from S3 paths.
Path convention: s3://<bucket>/amr-pipeline/<run-id>/<stage>/
"""

import os

import boto3


def get_s3_client():
    return boto3.client("s3")


def parse_s3_path(s3_path):
    """Parse s3://bucket/key into (bucket, key)."""
    assert s3_path.startswith("s3://"), f"Invalid S3 path: {s3_path}"
    parts = s3_path[5:].split("/", 1)
    bucket = parts[0]
    key = parts[1] if len(parts) > 1 else ""
    return bucket, key


def upload_directory(local_dir, s3_path):
    """Upload all files in local_dir to s3_path."""
    s3 = get_s3_client()
    bucket, prefix = parse_s3_path(s3_path)
    if prefix and not prefix.endswith("/"):
        prefix += "/"

    count = 0
    for root, _dirs, files in os.walk(local_dir):
        for filename in files:
            local_file = os.path.join(root, filename)
            relative = os.path.relpath(local_file, local_dir)
            s3_key = prefix + relative
            print(f"  Uploading {relative} -> s3://{bucket}/{s3_key}")
            s3.upload_file(local_file, bucket, s3_key)
            count += 1
    print(f"  Uploaded {count} files to {s3_path}")
    return count


def download_directory(s3_path, local_dir):
    """Download all objects under s3_path to local_dir."""
    s3 = get_s3_client()
    bucket, prefix = parse_s3_path(s3_path)
    if prefix and not prefix.endswith("/"):
        prefix += "/"

    os.makedirs(local_dir, exist_ok=True)
    paginator = s3.get_paginator("list_objects_v2")
    count = 0
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            relative = key[len(prefix):]
            if not relative:
                continue
            local_file = os.path.join(local_dir, relative)
            os.makedirs(os.path.dirname(local_file), exist_ok=True)
            print(f"  Downloading {relative}")
            s3.download_file(bucket, key, local_file)
            count += 1
    print(f"  Downloaded {count} files to {local_dir}")
    return count


def make_stage_path(bucket, run_id, stage_name):
    """Build the S3 path for a pipeline stage."""
    return f"s3://{bucket}/amr-pipeline/{run_id}/{stage_name}"
