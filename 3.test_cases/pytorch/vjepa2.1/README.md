<!-- Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved. -->
<!-- SPDX-License-Identifier: MIT-0 -->

# V-JEPA 2.1: Distributed Self-Supervised Video Pre-training

This test case demonstrates distributed pre-training of [V-JEPA 2.1](https://github.com/facebookresearch/vjepa2) (Meta FAIR) on AWS GPU clusters. V-JEPA 2.1 improves upon V-JEPA 2 with Dense Predictive Loss, Deep Self-Supervision, and image+video co-training to learn high-quality, temporally consistent dense features.

We benchmark the **ViT-g/16 (1B parameters)** encoder variant across 8 nodes of p5en.48xlarge instances (64 x NVIDIA H200 GPUs), with 50/50 image/video co-training.

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
| **Model** | V-JEPA 2.1 ViT-g/16 (1B params) |
| **Framework** | PyTorch + DDP |
| **Precision** | BF16 |
| **Paper** | [arXiv:2603.14482](https://arxiv.org/abs/2603.14482) |
| **Code** | [facebookresearch/vjepa2](https://github.com/facebookresearch/vjepa2) |

## What's New in V-JEPA 2.1 vs V-JEPA 2

| Feature | V-JEPA 2 | V-JEPA 2.1 |
|---------|----------|------------|
| Training data | Video only | Image + Video co-training (50/50 rank split) |
| Loss | Masked-token prediction only | Dense Predictive Loss (all tokens contribute) |
| Self-supervision | Single output layer | Deep: 4 intermediate layers concatenated |
| Predictor depth | 12 | 24 (doubled) |
| Context loss | None | Progressive warmup (0 -> 0.5 over iters 15k-30k) |
| Modality embeddings | None | Separate image vs video embeddings |
| Learning rate | 0.000525 | 0.0006 |

See also the [V-JEPA 2 test case](../vjepa2/) for the baseline benchmark.

## Prerequisites

- **Slurm cluster** on AWS with [Pyxis](https://github.com/NVIDIA/pyxis) and [Enroot](https://github.com/NVIDIA/enroot) for container support
- **p5en.48xlarge** instances (or similar GPU instances with NVIDIA H200)
- **EFA** (Elastic Fabric Adapter) networking enabled
- **FSx for Lustre** shared filesystem mounted at `/fsx`
- **Docker** installed on the cluster for building container images

## Shared Scripts

Several utility scripts (`generate_synthetic_dataset.py`, `nsys_wrapper.sh`, `prepare_ssv2.py`, `test_decord.py`) are shared with the [V-JEPA 2 test case](../vjepa2/) and symlinked from `../vjepa2/scripts/`. Ensure both directories are present when cloning.

## 1. Clone this repository

```bash
git clone https://github.com/awslabs/awsome-distributed-training.git
cd awsome-distributed-training/3.test_cases/pytorch/vjepa2.1
```

## 2. Datasets

V-JEPA 2.1 co-trains on images and video simultaneously. With `rank_ratio: 0.5`, half the GPU ranks process images and half process video.

### Video: Something-Something v2 (SSv2)

See the [V-JEPA 2 test case](../vjepa2/README.md#2-dataset-something-something-v2-ssv2) for SSv2 download and preparation instructions.

### Images: ImageNet-1K

For full pre-training, V-JEPA 2.1 uses ImageNet-1K images. Prepare a CSV with `<image_path> <label>` format:

```
/fsx/<your_username>/datasets/imagenet/train/n01440764/n01440764_18.JPEG 0
/fsx/<your_username>/datasets/imagenet/train/n01440764/n01440764_36.JPEG 0
...
```

### Alternative: Synthetic Datasets (for benchmarking)

For benchmarking without real datasets, generate synthetic data for both modalities:

```bash
# Synthetic video (reuse from V-JEPA 2 or generate new)
srun -N1 --ntasks=1 --cpus-per-task=48 -p p5en \
    --container-image /fsx/<your_username>/vjepa2.1/vjepa2.sqsh \
    --container-mounts /fsx:/fsx \
    python /vjepa2/scripts/generate_synthetic_dataset.py \
        --output_dir /fsx/<your_username>/vjepa2.1/datasets/synthetic \
        --num_videos 50000

# Synthetic images
srun -N1 --ntasks=1 --cpus-per-task=48 -p p5en \
    --container-image /fsx/<your_username>/vjepa2.1/vjepa2.sqsh \
    --container-mounts /fsx:/fsx \
    python /fsx/<your_username>/vjepa2.1/scripts/generate_synthetic_images.py \
        --output_dir /fsx/<your_username>/vjepa2.1/datasets/synthetic_images \
        --num_images 50000
```

> **Note**: Use at least 50,000 videos and 50,000 images for reliable benchmark
> numbers. With V-JEPA 2.1's rank_ratio=0.5 split, each rank sees only half
> the dataset; smaller datasets (e.g. 5,000) cause frequent data loader
> re-initialization that can inflate iteration times by up to 4x.

## 3. Build Container

V-JEPA 2.1 uses the **same container** as V-JEPA 2 (both apps live in the same repository). If you already have the V-JEPA 2 container, you can reuse it directly.

```bash
docker build -t vjepa2 -f vjepa2_1.Dockerfile .
enroot import dockerd://vjepa2
mv vjepa2.sqsh /fsx/<your_username>/vjepa2.1/
```

## 4. Update Configuration

Edit the config files under `configs/` to set paths for your environment:

```bash
# In configs/benchmark-vitg-8nodes.yaml:
# Update these paths:
#   folder: /fsx/<your_username>/vjepa2.1/benchmark/...
#   datasets: video CSV path
#   img_data.datasets: image CSV path

# Copy configs and scripts to shared storage:
mkdir -p /fsx/<your_username>/vjepa2.1/{configs,scripts}
cp configs/*.yaml /fsx/<your_username>/vjepa2.1/configs/
cp scripts/run_train.py /fsx/<your_username>/vjepa2.1/scripts/
```

The sbatch scripts use `${USER}` to construct paths automatically. If your layout differs, update `VJEPA21_DIR` in the sbatch files.

## 5. Run Benchmark

### Slurm

```bash
mkdir -p logs/vjepa21_benchmark
sbatch slurm/benchmark_training.sbatch
```

Monitor the job:

```bash
squeue -u $USER
tail -f logs/vjepa21_benchmark/<JOB_ID>.out
```

The benchmark runs 200 iterations across 8 nodes (64 GPUs). With `rank_ratio=0.5`, ranks 0-31 process images (batch size 72 per GPU) and ranks 32-63 process video (batch size 24 per GPU).

### Kubernetes

```bash
kubectl apply -f kubernetes/vjepa2-1-benchmark.yaml
kubectl logs -f pytorchjob/vjepa2-1-benchmark-worker-0
```

## 6. B200 GPU Setup

The standard container (based on `pytorch:25.03-py3`) ships NCCL 2.25 and an older aws-ofi-nccl plugin that are **incompatible with B200 EFA networking**. B200 scripts use a NeMo container with NCCL >= 2.29 instead. See the [V-JEPA 2 B200 setup](../vjepa2/README.md#7-b200-gpu-setup) for full prerequisite instructions.

## 7. Parse Results

```bash
python scripts/parse_benchmark.py \
    --log_file logs/vjepa21_benchmark/<JOB_ID>.out \
    --warmup_iters 20 \
    --batch_size_per_gpu 24 \
    --num_gpus 64 \
    --gpu_type h200
```

## Architecture Notes

### Launch pattern

Same as V-JEPA 2: **`srun` directly** (not `srun + torchrun`). The `run_train.py` launcher uses `app.scaffold.main()` which reads the `app: vjepa_2_1` field from the config to dispatch to `app.vjepa_2_1.train.main()`.

### Image/Video co-training rank split

With `img_data.rank_ratio: 0.5` on 64 GPUs:
- **Ranks 0-31** (32 GPUs): process images, batch size 72/GPU = 2,304 images/step
- **Ranks 32-63** (32 GPUs): process video, batch size 24/GPU = 768 videos/step

The code automatically adjusts the per-GPU video batch size to maintain the configured global batch size across the reduced number of video ranks. Each rank creates a single data loader for its assigned modality.

### GradScaler and BF16

The upstream V-JEPA 2/2.1 code unconditionally creates a `torch.cuda.amp.GradScaler()` for mixed-precision training. GradScaler is designed for FP16, where the narrow dynamic range can cause gradient underflow. BF16 has the same dynamic range as FP32, making the scale/unscale/step/update cycle pure overhead. The `run_train.py` launcher monkey-patches `GradScaler` to a no-op (`enabled=False`) when BF16 is configured, removing this unnecessary work.

### Model architecture

V-JEPA 2.1 ViT-g/16:
- **Encoder**: ViT-giant with `embed_dim=1408, depth=40, num_heads=22`
- **Predictor**: `depth=24, embed_dim=384, num_heads=12` (doubled from V-JEPA 2)
- **Deep Self-Supervision**: 4 intermediate layers (9, 19, 29, 39) concatenated -> `[B, N, 5632]`
- **Input**: 16 frames at 256x256 (video) or 1 frame at 256x256 (image)
- Uses `DistributedDataParallel` with EMA target encoder
- Activation checkpointing and BF16 mixed precision enabled

## 8. Profiling with nsys

Profile the training loop with NVIDIA Nsight Systems to identify GPU kernel bottlenecks, memory allocation patterns, and communication overhead. Only rank 0 is profiled to keep output sizes manageable.

```bash
mkdir -p logs/vjepa21_nsys

# Baseline profile
sbatch slurm/nsys_profile_b200.sbatch

# Profile a specific config (e.g. optimized)
NSYS_PROFILE_DIR=optimized \
CONFIG=/fsx/${USER}/vjepa2.1/configs/benchmark-vitg-8nodes-optimized.yaml \
    sbatch slurm/nsys_profile_b200.sbatch
```

Profiles are saved to `/fsx/${USER}/vjepa2.1/nsys/<profile_dir>/rank0.nsys-rep`. Open them with `nsys-ui` or download locally for analysis. Each optimization phase should use a different `NSYS_PROFILE_DIR` to keep profiles organized:

```
nsys/
├── baseline/          # Un-optimized baseline
├── optimized/         # torch.compile + no activation checkpointing
└── ...
```

## Benchmark Results

Use `scripts/parse_benchmark.py` to produce benchmark results from training logs. See Section 7 (Parse Results) for usage examples.

### Data Loading Optimization (TorchCodec)

The TorchCodec data loading optimization developed for V-JEPA 2 applies directly to V-JEPA 2.1 — both models use the same `run_train.py` launcher with environment-variable-controlled patches. On B200, where data loading accounts for 44% of iteration time, this optimization is critical.

Enable in your sbatch script:

```bash
export VJEPA_USE_TORCHCODEC=1      # Replace decord with TorchCodec
export VJEPA_CYCLING_SAMPLER=1     # Eliminate epoch boundary stalls (36.5% wall time improvement on B200)
```

The cycling sampler alone (without TorchCodec) already provides a **36.5% reduction** in per-iteration wall time on B200 by eliminating epoch boundary stalls where ranks wait for the slowest data loader to reinitialize. Combined with TorchCodec and increased workers (`num_workers: 16`), data loading time is expected to drop by 80%+ on B200.

See the [V-JEPA 2 README Section 10](../vjepa2/README.md#10-data-loading-optimization-torchcodec) for installation instructions and full details.

## References

- **V-JEPA 2.1 Paper**: [Unlocking Dense Features in Video Self-Supervised Learning](https://arxiv.org/abs/2603.14482)
- **V-JEPA 2 Paper**: [Self-Supervised Video Models Enable Understanding, Prediction and Planning](https://arxiv.org/abs/2506.09985)
- **Code**: [github.com/facebookresearch/vjepa2](https://github.com/facebookresearch/vjepa2)
- **Blog**: [ai.meta.com/blog/v-jepa-2-world-model-benchmarks](https://ai.meta.com/blog/v-jepa-2-world-model-benchmarks)
