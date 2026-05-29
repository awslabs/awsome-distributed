#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
"""
Launch a SageMaker Training Job for Isaac Lab.
Generated from config.yaml -- do not edit directly.

Usage:
    python launch-sm-training.py
    python launch-sm-training.py --iterations 500
    python launch-sm-training.py --dry-run
"""
import argparse
import json
import sys
from datetime import datetime

try:
    import boto3
except ImportError:
    print("ERROR: boto3 is required. Install with: pip install boto3", file=sys.stderr)
    sys.exit(1)


def launch(iterations: int = ${MAX_ITERATIONS}, dry_run: bool = False):
    region = "${AWS_REGION}"
    image = "${IMAGE}"
    role_arn = "${SM_ROLE_ARN}"
    scripts_s3 = "${SM_SCRIPTS_S3_URI}"
    output_s3 = "${SM_OUTPUT_S3_PATH}"
    checkpoint_s3 = "${SM_CHECKPOINT_S3_PATH}"
    instance_type = "${SM_INSTANCE_TYPE}"
    instance_count = ${SM_INSTANCE_COUNT}
    volume_size = ${SM_VOLUME_SIZE_GB}
    max_runtime = ${SM_MAX_RUNTIME}

    job_name = f"isaaclab-h1-{datetime.now().strftime('%Y%m%d-%H%M%S')}"

    job_config = {
        "TrainingJobName": job_name,
        "AlgorithmSpecification": {
            "TrainingImage": image,
            "TrainingInputMode": "File",
            "ContainerEntrypoint": ["/bin/bash", "-c"],
            "ContainerArguments": [
                "chmod +x /opt/ml/input/data/scripts/sm-train-entrypoint.sh && "
                "/opt/ml/input/data/scripts/sm-train-entrypoint.sh"
            ],
        },
        "RoleArn": role_arn,
        "InputDataConfig": [
            {
                "ChannelName": "scripts",
                "DataSource": {
                    "S3DataSource": {
                        "S3DataType": "S3Prefix",
                        "S3Uri": scripts_s3,
                        "S3DataDistributionType": "FullyReplicated",
                    }
                },
            }
        ],
        "OutputDataConfig": {"S3OutputPath": output_s3},
        "CheckpointConfig": {
            "S3Uri": checkpoint_s3,
            "LocalPath": "/opt/ml/checkpoints",
        },
        "ResourceConfig": {
            "InstanceType": instance_type,
            "InstanceCount": instance_count,
            "VolumeSizeInGB": volume_size,
        },
        "StoppingCondition": {"MaxRuntimeInSeconds": max_runtime},
        "EnableInterContainerTrafficEncryption": True,
        "Environment": {
            "ACCEPT_EULA": "Y",
            "PRIVACY_CONSENT": "Y",
            "NVIDIA_VISIBLE_DEVICES": "all",
            "NVIDIA_DRIVER_CAPABILITIES": "all",
            "MAX_ITERATIONS": str(iterations),
            "NCCL_DEBUG": "${SM_NCCL_DEBUG}",
            "MLFLOW_TRACKING_URI": "${MLFLOW_TRACKING_URI}",
            "MLFLOW_EXPERIMENT_NAME": "${MLFLOW_EXPERIMENT_NAME}",
            "SAGEMAKER_MLFLOW_ASSUME_ROLE_ARN": "${SAGEMAKER_MLFLOW_ASSUME_ROLE_ARN}",
            "MLFLOW_ENABLE_SYSTEM_METRICS_LOGGING": "true",
            "MLFLOW_SYSTEM_METRICS_SAMPLING_INTERVAL": "10",
        },
    }

    if dry_run:
        print("=== DRY RUN ===")
        print(json.dumps(job_config, indent=2))
        return

    sm = boto3.client("sagemaker", region_name=region)
    sm.create_training_job(**job_config)
    print(f"Launched SageMaker Training Job: {job_name}")
    print(f"  Region:    {region}")
    print(f"  Instances: {instance_count}x {instance_type}")
    print(f"  Iterations:{iterations}")
    print(f"  Output:    {output_s3}")
    print()
    print("Monitor with:")
    print(f"  aws sagemaker describe-training-job --training-job-name {job_name} --region {region}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Launch Isaac Lab SageMaker Training Job")
    parser.add_argument("--iterations", type=int, default=${MAX_ITERATIONS}, help="Max training iterations")
    parser.add_argument("--dry-run", action="store_true", help="Print job config without launching")
    args = parser.parse_args()
    launch(iterations=args.iterations, dry_run=args.dry_run)
