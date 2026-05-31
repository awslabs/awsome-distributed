#!/usr/bin/env python3
"""Stage 6: X-Mobility Navigation Model Training.

Downloads X-Mobility training datasets from S3, runs two-stage training
(world model pretraining + action policy), and uploads checkpoints and
metrics to S3.

X-Mobility is NVIDIA's end-to-end navigation foundation model (~1B params)
that takes RGB images and robot state as input and outputs action commands
directly. It uses a decoupled world model architecture: DINOv2 encoder +
GRU state estimator + latent diffusion decoder + action policy network.

Two-stage training:
  Stage 1 (world model): 160K random-action frames, trains state estimator
    and multi-task decoders (RGB reconstruction + semantic segmentation)
  Stage 2 (action policy): 100K Nav2 expert frames, jointly trains action
    policy with the world model

Reference: https://github.com/NVlabs/X-MOBILITY

Usage:
    python /scripts/stage6_train_evaluate.py \
        --s3_bucket my-bucket --run_id run-001

Prerequisites:
    Upload X-Mobility datasets (from HuggingFace nvidia/X-Mobility) to:
      s3://<bucket>/amr-pipeline/<run-id>/xmobility-datasets/
"""

import argparse
import functools
import json
import os
import subprocess
import sys
import time

print = functools.partial(print, flush=True)


def parse_args():
    parser = argparse.ArgumentParser(description="Stage 6: X-Mobility Training")
    parser.add_argument("--s3_bucket", type=str, required=True)
    parser.add_argument("--run_id", type=str, required=True)
    parser.add_argument("--dataset_dir", type=str, default="/input/datasets")
    parser.add_argument("--output_dir", type=str, default="/output/results")
    parser.add_argument("--xmobility_dir", type=str, default="/workspace/xmobility")
    parser.add_argument("--pretrain_epochs", type=int, default=10,
                        help="World model pretraining epochs (full training: 100)")
    parser.add_argument("--train_epochs", type=int, default=10,
                        help="Action policy training epochs (full training: 100)")
    parser.add_argument("--wandb_project", type=str, default="xmobility-osmo")
    parser.add_argument("--wandb_entity", type=str, default="")
    parser.add_argument("--skip_pretrain", action="store_true",
                        help="Skip world model pretraining, load checkpoint instead")
    parser.add_argument("--pretrain_checkpoint", type=str, default="",
                        help="S3 key for pre-trained world model checkpoint")
    return parser.parse_args()


def run_xmobility_train(xmobility_dir, config_path, dataset_dir, output_dir,
                        label, epochs=None, wandb_entity="", wandb_project="",
                        wandb_run=""):
    """Run X-Mobility training via its train.py entry point."""
    config_files = [config_path]

    # Override epoch count via a temporary gin config if specified
    if epochs is not None:
        epoch_override = os.path.join(output_dir, "epoch_override.gin")
        with open(epoch_override, "w") as f:
            f.write(f"NUM_EPOCHS={epochs}\n")
        config_files.append(epoch_override)

    cmd = [
        sys.executable, os.path.join(xmobility_dir, "train.py"),
        "-c", *config_files,
        "-d", dataset_dir,
        "-o", output_dir,
    ]
    if wandb_entity:
        cmd.extend(["-e", wandb_entity])
    if wandb_project:
        cmd.extend(["-n", wandb_project])
    if wandb_run:
        cmd.extend(["-r", wandb_run])

    print(f"[Stage6] Running {label}:")
    print(f"  Command: {' '.join(cmd)}")

    start = time.time()
    result = subprocess.run(
        cmd,
        cwd=xmobility_dir,
        env={**os.environ, "PYTHONPATH": xmobility_dir},
    )
    elapsed = time.time() - start

    print(f"[Stage6] {label} completed in {elapsed:.0f}s (exit code: {result.returncode})")
    if result.returncode != 0:
        print(f"[Stage6] ERROR: {label} failed")
        sys.exit(result.returncode)

    return elapsed


def main():
    args = parse_args()
    print("[Stage6] Starting X-Mobility training")

    import torch
    gpu_count = torch.cuda.device_count()
    print(f"[Stage6] GPUs: {gpu_count}, Pretrain epochs: {args.pretrain_epochs}, "
          f"Train epochs: {args.train_epochs}")

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from amr_utils.s3_sync import download_directory, upload_directory, make_stage_path

    os.makedirs(args.dataset_dir, exist_ok=True)
    os.makedirs(args.output_dir, exist_ok=True)

    # Download X-Mobility datasets from S3 (pre-cached from HuggingFace)
    dataset_s3 = make_stage_path(args.s3_bucket, args.run_id, "xmobility-datasets")
    print(f"[Stage6] Downloading X-Mobility datasets from {dataset_s3}")
    download_directory(dataset_s3, args.dataset_dir)

    dataset_contents = os.listdir(args.dataset_dir) if os.path.exists(args.dataset_dir) else []
    print(f"[Stage6] Dataset directory: {dataset_contents}")

    if not dataset_contents:
        print("[Stage6] ERROR: No dataset files found.")
        print(f"  Upload X-Mobility datasets to: s3://{args.s3_bucket}/amr-pipeline/{args.run_id}/xmobility-datasets/")
        print("  Download from: https://huggingface.co/datasets/nvidia/X-Mobility")
        sys.exit(1)

    # Verify X-Mobility source exists
    train_py = os.path.join(args.xmobility_dir, "train.py")
    if not os.path.exists(train_py):
        print(f"[Stage6] ERROR: X-Mobility source not found at {args.xmobility_dir}")
        sys.exit(1)

    pretrain_config = os.path.join(args.xmobility_dir, "configs", "pretrained_gwm_train_config.gin")
    train_config = os.path.join(args.xmobility_dir, "configs", "train_config.gin")
    pretrain_output = os.path.join(args.output_dir, "pretrain")
    train_output = os.path.join(args.output_dir, "train")

    # X-Mobility expects <path>/train/<scenario>/<files> structure
    # random_160k for world model pretraining, nav2_100k for action policy
    pretrain_dataset = os.path.join(args.dataset_dir, "afm_isaac_sim_random_160k", "data")
    train_dataset = os.path.join(args.dataset_dir, "afm_isaac_sim_nav2_100k", "data")
    print(f"[Stage6] Pretrain dataset: {pretrain_dataset} (exists: {os.path.isdir(pretrain_dataset)})")
    print(f"[Stage6] Train dataset: {train_dataset} (exists: {os.path.isdir(train_dataset)})")

    os.makedirs(pretrain_output, exist_ok=True)
    os.makedirs(train_output, exist_ok=True)

    metrics = {
        "model": "X-Mobility navigation foundation model (~1B params)",
        "architecture": "DINOv2 encoder + GRU world model + latent diffusion + action policy",
        "reference": "https://github.com/NVlabs/X-MOBILITY",
        "gpu_count": gpu_count,
        "stages": {},
    }

    # Stage 1: World model pretraining (state estimator + decoders)
    if args.skip_pretrain and args.pretrain_checkpoint:
        print("[Stage6] Skipping world model pretraining (using checkpoint)")
        ckpt_s3 = f"s3://{args.s3_bucket}/{args.pretrain_checkpoint}"
        print(f"[Stage6] Downloading checkpoint from {ckpt_s3}")
        download_directory(ckpt_s3, pretrain_output)
        metrics["stages"]["pretrain"] = {"skipped": True, "checkpoint": args.pretrain_checkpoint}
    else:
        print(f"\n[Stage6] === World Model Pretraining ({args.pretrain_epochs} epochs) ===")
        pretrain_time = run_xmobility_train(
            args.xmobility_dir, pretrain_config,
            pretrain_dataset, pretrain_output,
            label="WorldModelPretrain",
            epochs=args.pretrain_epochs,
            wandb_entity=args.wandb_entity,
            wandb_project=args.wandb_project,
            wandb_run=f"{args.run_id}-pretrain",
        )
        metrics["stages"]["pretrain"] = {
            "epochs": args.pretrain_epochs,
            "duration_seconds": pretrain_time,
            "config": "pretrained_gwm_train_config.gin",
        }

        # Upload intermediate checkpoint
        pretrain_s3 = make_stage_path(args.s3_bucket, args.run_id, "checkpoints/pretrain")
        print(f"[Stage6] Uploading pretrain checkpoint to {pretrain_s3}")
        upload_directory(pretrain_output, pretrain_s3)

    # Stage 2: Action policy training (joint world model + policy)
    print(f"\n[Stage6] === Action Policy Training ({args.train_epochs} epochs) ===")
    train_time = run_xmobility_train(
        args.xmobility_dir, train_config,
        train_dataset, train_output,
        label="ActionPolicyTrain",
        epochs=args.train_epochs,
        wandb_entity=args.wandb_entity,
        wandb_project=args.wandb_project,
        wandb_run=f"{args.run_id}-train",
    )
    metrics["stages"]["train"] = {
        "epochs": args.train_epochs,
        "duration_seconds": train_time,
        "config": "train_config.gin",
    }

    # Save metrics
    with open(os.path.join(args.output_dir, "metrics.json"), "w") as f:
        json.dump(metrics, f, indent=2)

    print(f"\n[Stage6] === Training Complete ===")
    for stage_name, stage_info in metrics["stages"].items():
        if stage_info.get("skipped"):
            print(f"  {stage_name}: skipped (used checkpoint)")
        else:
            print(f"  {stage_name}: {stage_info['epochs']} epochs in {stage_info['duration_seconds']:.0f}s")

    # Upload final results
    results_s3 = make_stage_path(args.s3_bucket, args.run_id, "results")
    print(f"\n[Stage6] Uploading results to {results_s3}")
    upload_directory(args.output_dir, results_s3)

    print("[Stage6] Done.")


if __name__ == "__main__":
    main()
