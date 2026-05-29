# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Visualization Scripts (Workshop / DCV Path)

These scripts are designed for the **EC2 + NICE DCV workshop path** and are **not** part of the HyperPod EKS or SageMaker Training Job flows.

They run Isaac Sim in a Docker container on a DCV-enabled EC2 instance with a local GPU, mounting a shared EFS volume for model checkpoints.

## Prerequisites

- EC2 instance with NICE DCV and an NVIDIA GPU
- Docker with NVIDIA Container Toolkit
- Shared EFS mounted at `/home/ubuntu/environment/shared-efs/`
- Isaac Lab container image available locally

## Scripts

| Script | Description |
|--------|-------------|
| `run-h1-demo.sh` | Interactive H1 locomotion demo (arrow keys to control) |
| `run-skrl-play.sh [path]` | Replay a trained skrl checkpoint (default: latest `best_agent.pt`) |
| `run-tensorboard.sh` | Launch TensorBoard on port 6006 |

## Usage

```bash
# Open a terminal in the DCV desktop
cd ~/environment/viz-scripts
./run-h1-demo.sh        # Pre-trained demo
./run-skrl-play.sh      # HyperPod-trained model playback
```
