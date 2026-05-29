#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
"""
Generate Kubernetes manifests and launch scripts from config.yaml.

Usage:
    python generate.py                    # uses config.yaml
    python generate.py --config my.yaml   # uses custom config file
    python generate.py --dry-run          # print what would be generated
"""

import argparse
import os
import sys
import yaml
from string import Template
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
TEMPLATES_DIR = SCRIPT_DIR / "templates"
OUTPUT_DIR = SCRIPT_DIR / "generated"


def load_config(config_path: str) -> dict:
    with open(config_path) as f:
        cfg = yaml.safe_load(f)

    # Derive computed values
    account_id = cfg["aws"]["account_id"]
    region = cfg["aws"]["region"]
    ecr_repo = cfg["ecr"]["repository"]
    ecr_tag = cfg["ecr"]["tag"]
    bucket = cfg["s3"]["bucket"]

    if not account_id:
        print("ERROR: aws.account_id is required in config.yaml", file=sys.stderr)
        sys.exit(1)
    if not bucket:
        print("ERROR: s3.bucket is required in config.yaml", file=sys.stderr)
        sys.exit(1)

    # Auto-derive ECR image URI if not explicitly set
    image = cfg["hyperpod_eks"].get("image") or ""
    if not image:
        image = f"{account_id}.dkr.ecr.{region}.amazonaws.com/{ecr_repo}:{ecr_tag}"
    cfg["_image"] = image

    # Auto-derive SageMaker S3 paths if not set
    sm = cfg["sagemaker_training"]
    if not sm.get("scripts_s3_uri"):
        sm["scripts_s3_uri"] = f"s3://{bucket}/scripts/sm-train-entrypoint.sh"
    if not sm.get("output_s3_path"):
        sm["output_s3_path"] = f"s3://{bucket}/sm-training-output/"
    if not sm.get("checkpoint_s3_path"):
        sm["checkpoint_s3_path"] = f"s3://{bucket}/sm-training-checkpoints/"
    prefix = sm.get("checkpoint_prefix", "default")
    sm["_checkpoint_s3_uri"] = sm["checkpoint_s3_path"].rstrip("/") + "/" + prefix + "/"

    return cfg


def build_vars(cfg: dict) -> dict:
    """Build the template variable map from config."""
    hpod = cfg["hyperpod_eks"]
    sm = cfg["sagemaker_training"]
    training = cfg["training"]
    image = cfg["_image"]

    job = hpod["jobs"]["training_job"]

    return {
        # Common
        "IMAGE": image,
        "AWS_REGION": cfg["aws"]["region"],
        "TASK": training["task"],
        "MAX_ITERATIONS": str(training["max_iterations"]),
        "FRAMEWORK": training["framework"],
        # HyperPod EKS
        "FSX_PVC_NAME": hpod["storage"]["fsx_pvc_name"],
        "NODE_HEALTH_LABEL": hpod["node_health_label"],
        "NODE_HEALTH_VALUE": hpod["node_health_value"],
        # FSx storage
        "FSX_FILE_SYSTEM_ID": hpod["fsx"]["file_system_id"],
        "FSX_DNS_NAME": hpod["fsx"]["dns_name"],
        "FSX_MOUNT_NAME": hpod["fsx"]["mount_name"],
        "FSX_CAPACITY": hpod["fsx"]["capacity"],
        # Training job
        "JOB_INSTANCE_TYPE": job["instance_type"],
        "JOB_GPUS": str(job["gpus_per_node"]),
        "JOB_NUM_NODES": str(job["num_nodes"]),
        "WORKER_REPLICAS": str(job["num_nodes"] - 1),
        "JOB_MEM_LIMIT": job["memory_limit"],
        "JOB_MEM_REQUEST": job["memory_request"],
        "JOB_CPU_LIMIT": job["cpu_limit"],
        "JOB_CPU_REQUEST": job["cpu_request"],
        "JOB_SHM": job["shm_size"],
        "JOB_FSX_LOG_DIR": job["fsx_log_dir"],
        # SageMaker Training
        "SM_ROLE_ARN": sm["role_arn"],
        "SM_INSTANCE_TYPE": sm["instance_type"],
        "SM_INSTANCE_COUNT": str(sm["instance_count"]),
        "SM_VOLUME_SIZE_GB": str(sm["volume_size_gb"]),
        "SM_MAX_RUNTIME": str(sm["max_runtime_seconds"]),
        "SM_SCRIPTS_S3_URI": sm["scripts_s3_uri"],
        "SM_OUTPUT_S3_PATH": sm["output_s3_path"],
        "SM_CHECKPOINT_S3_PATH": sm["_checkpoint_s3_uri"],
        "SM_NCCL_DEBUG": sm.get("environment", {}).get("NCCL_DEBUG", "INFO"),
        # Visualization
        "VIZ_GPU_INSTANCE_TYPE": cfg.get("viz", {}).get(
            "gpu_instance_type", "ml.g6.12xlarge"
        ),
        "VIZ_NUM_ENVS": str(cfg.get("viz", {}).get("num_envs", 25)),
        "VIZ_FSX_LOG_DIR": cfg.get("viz", {}).get("fsx_log_dir", job["fsx_log_dir"]),
        # MLflow
        "MLFLOW_TRACKING_URI": cfg.get("mlflow", {}).get("tracking_uri", ""),
        "MLFLOW_EXPERIMENT_NAME": cfg.get("mlflow", {}).get(
            "experiment_name", "isaaclab-h1"
        ),
        "SAGEMAKER_MLFLOW_ASSUME_ROLE_ARN": cfg.get("mlflow", {}).get(
            "assume_role_arn", ""
        ),
    }


def render_template(template_path: Path, variables: dict) -> str:
    """Render a template file using $VARIABLE substitution."""
    content = template_path.read_text()
    # Use safe_substitute so missing vars don't crash
    return Template(content).safe_substitute(variables)


def generate(config_path: str, dry_run: bool = False):
    cfg = load_config(config_path)
    variables = build_vars(cfg)

    if not TEMPLATES_DIR.exists():
        print(f"ERROR: Templates directory not found: {TEMPLATES_DIR}", file=sys.stderr)
        sys.exit(1)

    if not dry_run:
        OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    template_files = sorted(TEMPLATES_DIR.glob("*.yaml.tpl")) + sorted(
        TEMPLATES_DIR.glob("*.py.tpl")
    )

    if not template_files:
        print(f"ERROR: No template files found in {TEMPLATES_DIR}", file=sys.stderr)
        sys.exit(1)

    print(f"Config:    {config_path}")
    print(f"Templates: {TEMPLATES_DIR}")
    print(f"Output:    {OUTPUT_DIR}")
    print(f"Image:     {variables['IMAGE']}")
    print(f"Task:      {variables['TASK']}")
    print(f"Iterations:{variables['MAX_ITERATIONS']}")
    print()

    for tpl_path in template_files:
        # Remove .tpl suffix for output filename
        out_name = tpl_path.stem  # e.g. "training-job.yaml"
        out_path = OUTPUT_DIR / out_name
        rendered = render_template(tpl_path, variables)

        if dry_run:
            print(f"  [DRY RUN] Would write: {out_path}")
        else:
            out_path.write_text(rendered)
            print(f"  Generated: {out_path}")

            # Make .py files executable
            if out_name.endswith(".py"):
                out_path.chmod(0o755)

    if not dry_run:
        print()
        print("Done! Next steps:")
        print()
        print("  # HyperPod EKS - apply storage (one-time):")
        print("  kubectl apply -f generated/storage.yaml")
        print()
        print("  # HyperPod EKS - launch training:")
        print("  kubectl apply -f generated/training-job.yaml")
        print()
        print("  # HyperPod EKS - TensorBoard:")
        print("  kubectl apply -f generated/tensorboard.yaml")
        print()
        print("  # SageMaker Training Jobs:")
        print("  python generated/launch-sm-training.py")


def main():
    parser = argparse.ArgumentParser(
        description="Generate Isaac Lab training manifests from config"
    )
    parser.add_argument(
        "--config",
        default="config.yaml",
        help="Path to config file (default: config.yaml)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be generated without writing files",
    )
    args = parser.parse_args()

    if not os.path.exists(args.config):
        print(f"ERROR: Config file not found: {args.config}", file=sys.stderr)
        print(
            f"  Copy config.yaml.example to config.yaml and fill in your values.",
            file=sys.stderr,
        )
        sys.exit(1)

    generate(args.config, args.dry_run)


if __name__ == "__main__":
    main()
