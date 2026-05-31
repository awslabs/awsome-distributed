# OpenVLA Fine-Tuning on HyperPod Slurm

Fine-tune [OpenVLA-7B](https://github.com/openvla/openvla) (Vision-Language-Action model) on the LIBERO robotics benchmark using LoRA, distributed across 8 GPUs on a SageMaker HyperPod Slurm cluster.

## Prerequisites

- SageMaker HyperPod cluster with Slurm scheduler, [Pyxis](https://github.com/NVIDIA/pyxis)/[Enroot](https://github.com/NVIDIA/enroot), and P5/P5en GPU nodes
- FSx for Lustre shared filesystem mounted at `/fsx`
- Docker installed (for building the container image)
- SSH access to the cluster login node

## 1. Clone this repository

```bash
git clone https://github.com/awslabs/awsome-distributed-training.git
cd awsome-distributed-training/3.test_cases/pytorch/openvla
```

## 2. Build the container

```bash
docker build -t openvla-finetune -f openvla.Dockerfile .
```

## 3. Import as Enroot squashfs image

Transfer to the cluster and import:

```bash
enroot import -o /fsx/$USER/vla/openvla-finetune.sqsh dockerd://openvla-finetune:latest
```

## 4. Set up the cluster workspace

SSH into your cluster:

```bash
export VLA_HOME=/fsx/$USER/vla
mkdir -p $VLA_HOME/{models,data,checkpoints,logs,scripts}
```

## 5. Download model weights

```bash
python3 -c "
from huggingface_hub import snapshot_download
snapshot_download('openvla/openvla-7b-prismatic', local_dir='$VLA_HOME/models/openvla-7b')
"
```

## 6. Download the LIBERO dataset

```bash
python3 -c "
import tensorflow_datasets as tfds
builder = tfds.builder('libero_10_no_noops', data_dir='$VLA_HOME/data/libero_rlds')
builder.download_and_prepare()
"
```

## 7. Launch training

From `$VLA_HOME` (logs are written relative to the submission directory):

```bash
cd $VLA_HOME
cp ~/awsome-distributed-training/3.test_cases/pytorch/openvla/slurm/finetune_openvla.sbatch scripts/
sbatch scripts/finetune_openvla.sbatch
```

Monitor progress:

```bash
squeue -u $USER
tail -f logs/openvla-finetune/<JOB_ID>.out
```

Expected: ~10 minutes for 500 steps on 1 node (8x H200). Checkpoints saved to `$VLA_HOME/checkpoints/run_<JOB_ID>/`.

## 8. Verify output

```bash
ls -lh $VLA_HOME/checkpoints/run_<JOB_ID>/
# Expected: ~15 GB merged model (4 safetensors shards + config)
```

## Configuration

Training hyperparameters can be overridden via environment variables before submitting:

```bash
export MAX_STEPS=1000
export LEARNING_RATE=2e-4
export BATCH_SIZE=8
export LORA_RANK=64
sbatch scripts/finetune_openvla.sbatch
```

| Variable | Default | Description |
|----------|---------|-------------|
| `VLA_HOME` | `/fsx/$USER/vla` | Base workspace path |
| `MAX_STEPS` | `500` | Total training steps |
| `LEARNING_RATE` | `5e-4` | LoRA learning rate |
| `BATCH_SIZE` | `16` | Per-device batch size |
| `LORA_RANK` | `32` | LoRA adapter rank |
| `SAVE_STEPS` | `500` | Checkpoint interval |
| `WANDB_MODE` | `disabled` | Set to `online` to enable W&B logging |

## File Structure

```
openvla/
├── README.md               # This file
├── openvla.Dockerfile      # Training container (pinned deps)
├── .gitignore
└── slurm/
    └── finetune_openvla.sbatch  # Slurm batch script (srun + torchrun + LoRA)
```

## References

- [OpenVLA](https://github.com/openvla/openvla) — Vision-Language-Action model
- [LIBERO](https://libero-project.github.io/) — Robotic manipulation benchmark
- [SageMaker HyperPod](https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod.html)
- [Pyxis + Enroot](https://github.com/NVIDIA/pyxis) — Container runtime for Slurm
