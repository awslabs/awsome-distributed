# LeRobot pi0-FAST — DROID VLA Training

Multi-node distributed training of a Vision-Language-Action (VLA) policy using
[LeRobot](https://github.com/huggingface/lerobot) with the
[pi0-FAST](https://huggingface.co/docs/lerobot/en/pi0fast) architecture
(SigLIP vision encoder + Gemma 2B language backbone) on the
[DROID 1.0.1](https://huggingface.co/datasets/lerobot/droid_1.0.1) dataset
(76k+ real-robot trajectories, multi-camera, 1.7TB).

This test case exercises multi-node data-parallel scaling with a realistic
Physical AI workload: multi-stream video decode, language conditioning,
proprioceptive state, and action chunking over EFA-connected GPU instances.

## Prerequisites

- AWS infrastructure set up per [1.architectures/](../../../../1.architectures/)
- Slurm cluster with Enroot/Pyxis (SageMaker HyperPod or ParallelCluster)
- P5 (H100) or P6 (B200) instances with EFA networking
- HuggingFace Hub token with access to gated models (Gemma 2B used by pi0-FAST)
- Shared filesystem (FSx for Lustre) for dataset caching and checkpoints

## Quick Start

### 1. Configure Environment

```bash
cp env_vars.example env_vars
# Edit env_vars with your HF_TOKEN, output directory, etc.
source env_vars
```

### 2. Build the Container

```bash
make all
```

This builds the Docker image, converts it to an Enroot `.sqsh` file for Pyxis.

### 3. Run on Slurm (Multi-Node)

```bash
# 2-node training (default)
sbatch slurm/run.sh

# Scale to more nodes
sbatch --nodes=4 slurm/run.sh

# Override dataset or model
DATASET_REPO_ID=lerobot/aloha_sim_transfer_cube_human \
BATCH_SIZE=8 STEPS=50000 \
sbatch slurm/run.sh
```

### 4. Run on Slurm (Single-Node)

```bash
sbatch --nodes=1 slurm/run.sh
```

## Architecture

```
┌─────────────────────────────────────────────────┐
│ Slurm Job (N nodes)                             │
│                                                 │
│  Node 0 (rank 0)          Node 1 (rank 1)       │
│  ┌─────────────────┐      ┌─────────────────┐   │
│  │ accelerate       │      │ accelerate       │   │
│  │ launch           │◄────►│ launch           │   │
│  │  └─ 8 GPU workers│ EFA  │  └─ 8 GPU workers│   │
│  │     lerobot-train│      │     lerobot-train│   │
│  └─────────────────┘      └─────────────────┘   │
│           │                         │            │
│           └────────┬────────────────┘            │
│                    │                             │
│           ┌────────▼────────┐                    │
│           │ DROID Dataset   │                    │
│           │ (HF Hub / FSx)  │                    │
│           └─────────────────┘                    │
└─────────────────────────────────────────────────┘
```

- **Launcher**: HuggingFace Accelerate (wraps torchrun for distributed setup)
- **Distribution**: DDP via `accelerate launch` — one process per node, each spawning 8 GPU workers
- **Rendezvous**: c10d backend with head node IP from Slurm
- **Dataset**: Streamed from HuggingFace Hub or pre-cached on shared filesystem

## Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `NUM_NODES` | `2` | Number of Slurm nodes (set via `--nodes`) |
| `GPUS_PER_NODE` | `8` | GPUs per node (8 for P5/P6) |
| `DATASET_REPO_ID` | `lerobot/droid_1.0.1` | HuggingFace dataset repo ID |
| `PRETRAINED_PATH` | `lerobot/pi0fast_base` | Pretrained model to fine-tune |
| `BATCH_SIZE` | `4` | Per-GPU batch size |
| `STEPS` | `200000` | Total training steps |
| `OUTPUT_DIR` | `/fsx/lerobot-output` | Checkpoint and log output directory |
| `HF_HOME` | (system default) | HuggingFace cache directory |
| `HF_TOKEN` | (required) | HuggingFace Hub token for gated models |

### pi0-FAST Policy Parameters

These are set in `slurm/run.sh` and can be adjusted:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `policy.dtype` | `bfloat16` | Mixed precision dtype |
| `policy.gradient_checkpointing` | `true` | Reduce memory via activation checkpointing |
| `policy.chunk_size` | `10` | Action prediction horizon |
| `policy.n_action_steps` | `10` | Number of action steps to execute |
| `policy.max_action_tokens` | `256` | Max FAST tokenizer output tokens |

## Scaling Variants

### Variant A: Compute-Heavy (DDP Scaling Test)

Increase model compute to stress gradient synchronization:

```bash
# Use larger action horizons and higher resolution
TRAIN_ARGS="... --policy.chunk_size=20 --policy.n_action_steps=20"
```

### Variant B: Data-Heavy (I/O Scaling Test)

Stress the data pipeline with DROID's multi-camera streams:

```bash
# Increase dataloader workers and prefetch
TRAIN_ARGS="... --dataloader.num_workers=8"
```

## Metrics to Measure

- **Samples/sec** and scaling efficiency from 1 to N nodes
- **GPU utilization** and step time breakdown (forward/backward vs allreduce vs data loading)
- **Data throughput**: video decode frames/sec per node
- **Checkpoint throughput**: time to save/load checkpoints at scale
- **Loss curve consistency**: verify same loss trajectory across different node counts

## Troubleshooting

### DROID Dataset Download

DROID 1.0.1 is ~1.7TB. Pre-cache it on shared filesystem before training:

```python
from lerobot.common.datasets.lerobot_dataset import LeRobotDataset
ds = LeRobotDataset("lerobot/droid_1.0.1")
```

### HuggingFace Token for Gated Models

pi0-FAST uses Gemma 2B (gated). Log in before training:

```bash
huggingface-cli login --token $HF_TOKEN
```

### EFA Verification

Verify EFA is working on each node:

```bash
fi_info -p efa
```

## License

This project is licensed under MIT-0. See [LICENSE](../../../../LICENSE).
