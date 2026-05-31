# Warehouse AMR Navigation Pipeline on NVIDIA OSMO

MobilityGen-style synthetic data generation pipeline for warehouse AMR (Autonomous Mobile Robot) navigation, running on Amazon EKS with NVIDIA OSMO orchestration and KAI Scheduler.

## Overview

A 6-stage AMR pipeline orchestrated as an OSMO DAG: from scene generation through rendering, domain augmentation, and X-Mobility foundation model training.

Stage 6 trains NVIDIA's [X-Mobility](https://github.com/NVlabs/X-MOBILITY) navigation foundation model (~1B params) on MobilityGen-generated datasets, using Karpenter-managed capacity reservations for training compute.

### 6-Stage Pipeline Architecture

```
scene-setup --> occupancy-map --> trajectory-gen --> render --+--> domain-augment --> train-evaluate
                                                             |                            ^
                                                             +----------------------------+
```

| Stage | Script | Image | GPU Pool | Purpose |
|-------|--------|-------|----------|---------|
| 1. Scene Setup | `stage1_scene_setup.py` | isaac-sim-amr | G-series (rendering) | Build warehouse USD scene |
| 2. Occupancy Map | `stage2_occupancy_map.py` | isaac-sim-amr | G-series (rendering) | 2D occupancy grid from prim geometry |
| 3. Trajectory Gen | `stage3_trajectory_gen.py` | isaac-sim-amr | G-series (rendering) | A* path planning + camera poses |
| 4. Render | `stage4_render.py` | isaac-sim-amr | G-series (rendering) | RGB/depth/segmentation rendering |
| 5. Domain Augment | `stage5_domain_augment.py` | cosmos-transfer-amr | G-series (rendering) | Visual augmentation (torchvision, Cosmos Transfer-compatible) |
| 6. Train+Eval | `stage6_train_evaluate.py` | xmobility-amr | P-series (training) | X-Mobility foundation model training (8 GPUs) |

**OSMO orchestration features used:**
- DAG task dependencies via `inputs:`
- KAI Scheduler assignment via `schedulerName: kai-scheduler`
- Priority scheduling via `priority: medium`
- Checkpoint/reschedule semantics via `exitAction: reschedule` on training stage
- Heterogeneous compute: G-series (rendering) and P-series (training) NodePools

**Data passing**: S3 bucket via IRSA. Path: `s3://<bucket>/amr-pipeline/<run-id>/<stage>/`

## Prerequisites

- Amazon EKS cluster with GPU nodes (G5/G6 for rendering, P-series for training)
- NVIDIA GPU Operator + KAI Scheduler + OSMO Platform installed
- Karpenter with 4 OSMO NodePools (osmo-rendering, osmo-gpu-od, osmo-cpu-batch, osmo-cpu-system)
- [NVIDIA NGC](https://ngc.nvidia.com/) account and API key
- X-Mobility datasets from [HuggingFace](https://huggingface.co/datasets/nvidia/X-Mobility), pre-cached in S3
- S3 bucket for inter-stage data + IRSA ServiceAccount
- Docker, `kubectl`, and AWS CLI configured

## Quick Start

```bash
# 1. Setup
./kubernetes/0.setup-ngc-secret.sh

# 2. Build all 3 images
./kubernetes/1.build-container.sh

# 3. Verify OSMO is ready
./kubernetes/4.verify-osmo.sh

# 4. Submit pipeline
export S3_BUCKET="my-amr-pipeline-bucket"
./kubernetes/3.submit-pipeline.sh
```

See [kubernetes/README.md](kubernetes/README.md) for detailed per-stage instructions.

## Configuration

- `configs/default_config.yaml` - Pipeline-level settings
- `configs/pipeline_config.yaml` - Per-stage pipeline parameters

## Container Images

| Image | Dockerfile | Base | Stages |
|-------|-----------|------|--------|
| `isaac-sim-amr` | `Dockerfile.isaac-sim` | Isaac Sim 5.1.0 | 1-4 (scene, occupancy, trajectory, render) |
| `cosmos-transfer-amr` | `Dockerfile.cosmos-transfer` | PyTorch 24.05 | 5 (domain augmentation) |
| `xmobility-amr` | `Dockerfile.xmobility` | PyTorch 24.01 + X-Mobility | 6 (X-Mobility foundation model training) |

## S3 Output Structure

```
s3://<bucket>/amr-pipeline/<run-id>/
  scene/              # warehouse_scene.usd + metadata.json
  occupancy/          # occupancy_map.npy + .png + metadata.json
  trajectories/       # trajectory_XXXX.json files + metadata.json
  raw-v1/             # rgb/ depth/ semantic_segmentation/
  augmented-v2/       # rgb/ depth/ semantic_segmentation/
  xmobility-datasets/ # X-Mobility training data (pre-cached from HuggingFace)
  checkpoints/        # pretrain/ and train/ checkpoints
  results/            # metrics.json + final model
```

## Instance Recommendations

| Instance | GPUs | GPU Memory | vCPUs | RAM | Use |
|----------|------|-----------|-------|-----|-----|
| g5.4xlarge | 1 | 24 GB | 16 | 64 GB | Stages 1-5 (rendering, augmentation) |
| g6.2xlarge | 1 | 24 GB | 8 | 32 GB | Stages 1-5 (latest gen) |
| p5.48xlarge | 8 | 640 GB | 192 | 2 TB | Stage 6 (X-Mobility training) |

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Vulkan ICD not found | Ensure GPU Operator toolkit is enabled (`toolkit.enabled=true`) |
| OOM kills | Use g5.4xlarge+ (64 GB RAM) for Isaac Sim stages |
| Shader compilation timeout | Increase `activeDeadlineSeconds` to 3600 on first run |
| S3 access denied | Verify IRSA ServiceAccount annotation matches IAM role ARN |
| Stage stuck on download | Check S3 bucket region matches cluster region |
| Training NaN loss | Reduce learning rate or check augmented data integrity |
