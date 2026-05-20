<!-- Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved. -->
<!-- SPDX-License-Identifier: MIT-0 -->

# V-JEPA 2: Distributed Self-Supervised Video Pre-training

This test case demonstrates distributed pre-training of [V-JEPA 2](https://github.com/facebookresearch/vjepa2) (Meta FAIR) on AWS GPU clusters. V-JEPA 2 is a self-supervised approach to training video encoders using internet-scale video data, achieving state-of-the-art performance on motion understanding and human action anticipation tasks.

We benchmark the **ViT-g/16 (1B parameters)** encoder variant using the **Something-Something v2 (SSv2)** video dataset across 8 nodes of p5en.48xlarge instances (64 x NVIDIA H200 GPUs).

> **Directory Structure Note**: V-JEPA 2 and V-JEPA 2.1 are maintained as
> separate test case directories (`vjepa2/` and `vjepa2.1/`) to mirror the
> upstream [facebookresearch/vjepa2](https://github.com/facebookresearch/vjepa2)
> repository structure, where `app/vjepa/` and `app/vjepa_2_1/` are distinct
> training applications with different model architectures, loss functions, and
> data pipelines. They share the same codebase and container image, but their
> configs, benchmarks, and launch patterns differ. Shared utility scripts are
> symlinked from `vjepa2/scripts/` to avoid duplication.

| | |
|---|---|
| **Model** | V-JEPA 2 ViT-g/16 (1B params) |
| **Framework** | PyTorch + DDP |
| **Precision** | BF16 |
| **Paper** | [arXiv:2506.09985](https://arxiv.org/abs/2506.09985) |
| **Code** | [facebookresearch/vjepa2](https://github.com/facebookresearch/vjepa2) |
| **HuggingFace** | [facebook/vjepa2-vitg-fpc64-256](https://huggingface.co/facebook/vjepa2-vitg-fpc64-256) |

## Prerequisites

- **Slurm cluster** on AWS with [Pyxis](https://github.com/NVIDIA/pyxis) and [Enroot](https://github.com/NVIDIA/enroot) for container support
- **p5en.48xlarge** instances (or similar GPU instances with NVIDIA H200)
- **EFA** (Elastic Fabric Adapter) networking enabled
- **FSx for Lustre** shared filesystem mounted at `/fsx`
- **Docker** installed on the cluster for building container images

## 1. Clone this repository

```bash
git clone https://github.com/awslabs/awsome-distributed-training.git
cd awsome-distributed-training/3.test_cases/pytorch/vjepa2
```

## 2. Dataset: Something-Something v2 (SSv2)

V-JEPA 2 trains on video data. This test case uses the [Something-Something v2](https://developer.qualcomm.com/software/ai-datasets/something-something) dataset (~169K training videos, 174 action categories).

**Visit the dataset URL above to check if you need to request access before downloading.**

### Download SSv2

After obtaining access, download the following files to `/fsx/<your_username>/vjepa2/datasets/ssv2/`:

- Video archive(s) (`.webm` files) -> extract to `videos/` subdirectory
- `labels.json` (template -> label index mapping)
- `train.json` (training split annotations)

Your directory structure should look like:

```
/fsx/<your_username>/vjepa2/datasets/ssv2/
├── videos/
│   ├── 12345.webm
│   ├── 12346.webm
│   └── ...
├── labels.json
└── train.json
```

### Generate training CSV

V-JEPA 2's dataloader expects a space-delimited CSV with `<video_path> <label>` per line. Generate it using:

```bash
python scripts/prepare_ssv2.py \
    --video_dir /fsx/<your_username>/vjepa2/datasets/ssv2/videos \
    --labels_json /fsx/<your_username>/vjepa2/datasets/ssv2/labels.json \
    --train_json /fsx/<your_username>/vjepa2/datasets/ssv2/train.json \
    --output_csv /fsx/<your_username>/vjepa2/datasets/ssv2/ssv2_train_paths.csv
```

Or submit via Slurm (update paths in the script first):

```bash
sbatch slurm/download_dataset.sbatch
```

### Alternative: Synthetic Dataset

For benchmarking without downloading SSv2, you can generate a synthetic video dataset:

```bash
srun -N1 --ntasks=1 --cpus-per-task=48 -p p5en \
    --container-image /fsx/<your_username>/vjepa2/vjepa2.sqsh \
    --container-mounts /fsx:/fsx \
    python /vjepa2/scripts/generate_synthetic_dataset.py \
        --output_dir /fsx/<your_username>/vjepa2/datasets/synthetic \
        --num_videos 50000
```

> **Note**: Use at least 50,000 videos for reliable benchmark numbers. Smaller
> datasets cause frequent data loader re-initialization between epochs, which
> inflates iteration times and masks true GPU throughput.

Then update your config to point to the generated CSV:
```yaml
datasets:
  - /fsx/<your_username>/vjepa2/datasets/synthetic/synthetic_train_paths.csv
```

## 3. Build Container

### Build Docker image

```bash
docker build -t vjepa2 -f vjepa2.Dockerfile .
```

### Test decord inside the container

`decord` is the video loading library used by V-JEPA 2. Verify it works:

```bash
# On a compute node with GPU access:
srun -N1 --ntasks=1 -p p5en \
    --container-image vjepa2 \
    python /vjepa2/scripts/test_decord.py
```

You should see:

```
=== Testing decord with: /tmp/.../test_video.mp4 ===
[1/4] Importing decord...
  OK: decord imported successfully
[2/4] Loading video...
  OK: 32 frames, avg fps: 4.0
[3/4] Reading frame batch...
  OK: batch shape = (16, 256, 256, 3), dtype = uint8
[4/4] Verifying frame content...
  OK: frames are valid (min=..., max=..., mean=...)
=== All decord tests passed ===
```

If decord fails, see the [vjepa2 README](https://github.com/facebookresearch/vjepa2#setup) for alternative packages (`eva-decord` or `decord2`).

### Convert to Enroot squashfs

```bash
enroot import dockerd://vjepa2
mv vjepa2.sqsh /fsx/<your_username>/vjepa2/
```

## 4. Update Configuration

Edit the config files under `configs/` to set paths for your environment:

```bash
# In configs/benchmark-vitg-8nodes.yaml (and pretrain-vitg-256px-16f.yaml):
# Update these paths:
#   folder: /fsx/<your_username>/vjepa2/benchmark/...
#   datasets: /fsx/<your_username>/vjepa2/datasets/ssv2/ssv2_train_paths.csv

# Copy configs and scripts to shared storage:
mkdir -p /fsx/<your_username>/vjepa2/configs
cp configs/*.yaml /fsx/<your_username>/vjepa2/configs/
cp scripts/run_train.py /fsx/<your_username>/vjepa2/scripts/
```

The sbatch scripts use `${USER}` to construct paths automatically. If your layout differs, update `VJEPA2_DIR` in the sbatch files.

## 5. Run Benchmark

### Slurm

```bash
mkdir -p logs/vjepa2_benchmark
sbatch slurm/benchmark_training.sbatch
```

Monitor the job:

```bash
squeue -u $USER
tail -f logs/vjepa2_benchmark/<JOB_ID>.out
```

The benchmark runs 200 iterations of V-JEPA 2 ViT-g/16 pre-training across 8 nodes (64 GPUs). Training logs report per-iteration: loss, iter-time (ms), GPU-time (ms), and data-load time (ms).

### Kubernetes

For EKS-based clusters, apply the PyTorchJob manifest:

```bash
# First push the container image to ECR, then update the image field
kubectl apply -f kubernetes/vjepa2-benchmark.yaml
kubectl logs -f pytorchjob/vjepa2-benchmark-worker-0
```

## 6. Parse Results

After the benchmark completes, parse the logs to compute throughput:

```bash
python scripts/parse_benchmark.py \
    --log_file logs/vjepa2_benchmark/<JOB_ID>.out \
    --warmup_iters 20 \
    --batch_size_per_gpu 24 \
    --num_gpus 64 \
    --gpu_type h200
```

## 7. B200 GPU Setup

The standard container (based on `pytorch:25.03-py3`) ships NCCL 2.25 and an older aws-ofi-nccl plugin that are **incompatible with B200 EFA networking**. B200 scripts use a NeMo container with NCCL >= 2.29 instead.

### Prerequisites (run once from the login node)

1. **Obtain a NeMo container** with NCCL 2.29+ and EFA support:
   ```bash
   enroot import 'docker://nvcr.io#nvidia/nemo:25.11.01'
   # Or use a pre-built .sqsh with the correct EFA/NCCL stack
   ```

2. **Clone the V-JEPA 2 repository** to shared storage:
   ```bash
   git clone https://github.com/facebookresearch/vjepa2.git \
       /fsx/${USER}/vjepa2_code
   ```

3. **Install V-JEPA 2 Python dependencies** into a shared directory (use the NeMo container to ensure compatible packages):
   ```bash
   srun --partition=b200 --account=root -N1 --ntasks=1 \
       --container-image /fsx/${USER}/nemo-efa-nccl29.sqsh \
       --container-mounts /fsx:/fsx --no-container-mount-home \
       pip install --target /fsx/${USER}/vjepa_deps \
           -r /fsx/${USER}/vjepa2_code/requirements.txt
   ```

4. **Copy configs and scripts** from this test case to shared storage (same as Section 4).

### Optimized Config (B200)

An optimized config is provided for B200 GPUs that enables `torch.compile` and disables activation checkpointing. This trades higher GPU memory usage (~95 GB/GPU vs ~33 GB) for ~23% faster iteration time.

```bash
mkdir -p logs/vjepa2_benchmark_opt
sbatch slurm/benchmark_training_b200_optimized.sbatch
```

| Setting | Baseline | Optimized |
|---------|----------|-----------|
| `compile_model` | false | true |
| `use_activation_checkpointing` | true | false |
| `num_workers` | 8 | 20 |
| GPU memory per device | ~33 GB | ~95 GB |

> **Note**: H200 GPUs have 141 GB HBM. Verify memory fits your workload before
> disabling activation checkpointing on H200 (it works fine on B200 with 178 GB).

## 8. Full Pre-training

For full pre-training (800 epochs):

```bash
sbatch slurm/launch_training.sbatch
```

## Architecture Notes

### Launch pattern

V-JEPA 2 uses **`srun` directly** (not `srun + torchrun`). Each `srun` task:

1. Reads `SLURM_LOCALID` to set `CUDA_VISIBLE_DEVICES` (1 GPU per process)
2. Reads `SLURM_NTASKS` and `SLURM_PROCID` to initialize `torch.distributed` via NCCL
3. Calls `app.vjepa.train.main()` directly via `scripts/run_train.py`

We use a thin launcher (`scripts/run_train.py`) that loads the YAML config and calls the V-JEPA 2 training entry point directly. This ensures each `srun` task correctly inherits SLURM environment variables for distributed initialization. The `--ntasks-per-node=8` in the sbatch header ensures 8 processes per node (one per GPU).

### GradScaler and BF16

The upstream V-JEPA 2 code unconditionally creates a `torch.cuda.amp.GradScaler()` for mixed-precision training. GradScaler is designed for FP16, where the narrow dynamic range can cause gradient underflow. BF16 has the same dynamic range as FP32, making the scale/unscale/step/update cycle pure overhead. The `run_train.py` launcher monkey-patches `GradScaler` to a no-op (`enabled=False`) when BF16 is configured, removing this unnecessary work.

### Model architecture

V-JEPA 2 ViT-g/16:
- **Encoder**: ViT-giant with `embed_dim=1408, depth=40, num_heads=22`
- **Predictor**: `depth=12, embed_dim=384, num_heads=12`
- **Input**: 16 frames at 256x256, `patch_size=16`, `tubelet_size=2`
- **Patches per sample**: `(256/16)^2 * (16/2) = 2048`
- Uses `DistributedDataParallel` with EMA target encoder
- Activation checkpointing and BF16 mixed precision enabled

## 9. Profiling with nsys

Profile the training loop with NVIDIA Nsight Systems to identify GPU kernel bottlenecks, memory allocation patterns, and communication overhead. Only rank 0 is profiled to keep output sizes manageable.

```bash
mkdir -p logs/vjepa2_nsys

# Baseline profile
sbatch slurm/nsys_profile_b200.sbatch

# Profile a specific config (e.g. after optimization)
NSYS_PROFILE_DIR=phase1_compile \
CONFIG=/fsx/${USER}/vjepa2/configs/benchmark-vitg-8nodes-optimized.yaml \
    sbatch slurm/nsys_profile_b200.sbatch
```

Profiles are saved to `/fsx/${USER}/vjepa2/nsys/<profile_dir>/rank0.nsys-rep`. Open them with `nsys-ui` or download locally for analysis. Each optimization phase should use a different `NSYS_PROFILE_DIR` to keep profiles organized:

```
nsys/
├── baseline/          # Un-optimized baseline
├── phase1_compile/    # torch.compile + no activation checkpointing
├── phase2_noscaler/   # GradScaler disabled for BF16
└── ...
```

## 10. Data Loading Optimization (TorchCodec)

[TorchCodec](https://github.com/pytorch/torchcodec) is a drop-in replacement for decord that provides faster video decode and releases the Python GIL during decode operations. Combined with increased DataLoader workers and a cycling sampler, it reduces data loading time by **83%** (140ms → 24ms on H200), making data loading completely hidden behind GPU compute.

### Quick Start

Enable via environment variables in your sbatch script (no code changes needed):

```bash
export VJEPA_USE_TORCHCODEC=1      # Replace decord with TorchCodec
export VJEPA_CYCLING_SAMPLER=1     # Eliminate epoch boundary stalls
```

And increase `num_workers` in your config YAML:

```yaml
data:
  num_workers: 16    # up from default 8
```

### Installation

TorchCodec must be installed with the CUDA wheel index (the default pip install gives a CPU-only build that errors on `device="cuda"`):

```bash
pip install torchcodec==0.10 --index-url=https://download.pytorch.org/whl/cu130
```

> **Note**: When using Pyxis containers with multiple tasks per node, serialize the
> install with `flock /tmp/tc_install.lock pip install ...` to avoid race conditions.

### Results (H200, 2 nodes × 8 GPUs, V-JEPA 2 ViT-g/16, bs=24)

| Configuration | iter_time (ms) | data_time (ms) | data_time reduction |
|---|---|---|---|
| Decord baseline (8 workers) | 1,825 | 140 | — |
| TorchCodec (8 workers) | 1,822 | 112 | 20% |
| **TorchCodec + 16 workers + cycling** | **1,712** | **24** | **83%** |

### How It Works

The `run_train.py` launcher applies monkey patches at startup based on environment variables:

- **`VJEPA_USE_TORCHCODEC=1`**: Replaces `VideoDataset.loadvideo_decord` with a TorchCodec equivalent that uses `seek_mode="approximate"` for faster seeks
- **`VJEPA_CYCLING_SAMPLER=1`**: Patches `DistributedSampler` and `DistributedWeightedSampler` to cycle infinitely, eliminating epoch boundary stalls where all workers wait for the slowest rank
- **`VJEPA_THREADED_DECODE=1`** (experimental): Replaces the multiprocess DataLoader with a threaded variant. Only beneficial for large (720p+) videos where decode dominates transforms

For the full investigation including GPU decode benchmarks, threaded DataLoader results, and microbenchmarks, run the profiling jobs described in Section 9.

## Benchmark Results

Use `scripts/parse_benchmark.py` to produce benchmark results from training logs after running the benchmark sbatch scripts. See Section 6 for usage examples.

## References

- **Paper**: [V-JEPA 2: Self-Supervised Video Models Enable Understanding, Prediction and Planning](https://arxiv.org/abs/2506.09985)
- **Code**: [github.com/facebookresearch/vjepa2](https://github.com/facebookresearch/vjepa2)
- **Blog**: [ai.meta.com/blog/v-jepa-2-world-model-benchmarks](https://ai.meta.com/blog/v-jepa-2-world-model-benchmarks)
- **HuggingFace models**: [V-JEPA 2 collection](https://huggingface.co/collections/facebook/v-jepa-2-6841bad8413014e185b497a6)
- **HuggingFace docs**: [transformers/model_doc/vjepa2](https://huggingface.co/docs/transformers/main/en/model_doc/vjepa2)
