# DeepSpeed on AWS <!-- omit in toc -->

[DeepSpeed](https://github.com/microsoft/DeepSpeed) is a deep learning optimization library that enables efficient distributed training at scale. This directory contains test cases for running DeepSpeed workloads on AWS GPU clusters, covering large-scale pretraining and parameter-efficient fine-tuning.

## Use Cases

| Use Case | Description | Location |
|----------|-------------|----------|
| GPT-103B Pretraining | Large-scale GPT pretraining benchmark using Megatron-DeepSpeed with 3D parallelism (TP/PP/DP) and ZeRO optimization | [`gpt/`](gpt/) |
| QLoRA Fine-tuning | Qwen3-8B fine-tuning with QLoRA (4-bit) + DeepSpeed ZeRO-2/3, supports EKS and Slurm | [`qlora/`](qlora/) |
| Llama2 Fine-tuning | Llama2 fine-tuning from HuggingFace weights using Megatron-DeepSpeed | [`examples_megatron_deepspeed/finetune_hf_llama/`](examples_megatron_deepspeed/finetune_hf_llama/) |

## Prerequisites

- A functional Slurm cluster on AWS. We recommend [SageMaker HyperPod](https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod.html) or the templates in the [architectures directory](../../1.architectures).
- [Docker](https://docs.docker.com/engine/install/), [Pyxis](https://github.com/NVIDIA/pyxis), and [Enroot](https://github.com/NVIDIA/enroot) installed on compute nodes.
- An [FSx for Lustre](https://docs.aws.amazon.com/fsx/latest/LustreGuide/what-is.html) filesystem mounted on `/fsx`.
- NVIDIA GPU instances with [EFA networking](https://aws.amazon.com/hpc/efa/) (B200, H100, A100, etc.).

## 1. GPT-103B Pretraining Benchmark

A ~103B-parameter GPT model (80 layers, hidden=12288, heads=96, FFN=49152) trained with [Megatron-DeepSpeed](https://github.com/microsoft/Megatron-DeepSpeed) using 3D parallelism (tensor, pipeline, data) and DeepSpeed ZeRO optimization. Designed for benchmarking multi-node GPU clusters.

### Container setup

The container image (`0.deepspeed.dockerfile`) is built on `nvcr.io/nvidia/pytorch:25.04-py3` and includes:

- **EFA 1.47.0** with the bundled aws-ofi-nccl plugin and NCCL tuner
- **NCCL 2.29.3** (upgraded to match B200 host driver)
- **GDRCopy v2.5.1** for GPU-direct RDMA
- **DeepSpeed**, **Transformers 4.44.2**, and multi-node SSH configuration

Build the container on a compute node (recommended, avoids head node storage limits):

```bash
sbatch 1.build-image.sbatch
```

Or build locally and convert to a squash file:

```bash
make build    # docker build
make import   # enroot import to /fsx/apps/deepspeed.sqsh
```

### Data preparation

The benchmark uses preprocessed data in Megatron format with the GPT-2 tokenizer.

1. Download the GPT-2 tokenizer:

   ```bash
   mkdir -p /fsx/deepspeed/data && cd /fsx/deepspeed/data
   wget https://s3.amazonaws.com/models.huggingface.co/bert/gpt2-vocab.json
   wget https://s3.amazonaws.com/models.huggingface.co/bert/gpt2-merges.txt
   ```

2. Prepare training data (any text corpus works; for benchmarking, synthetic data is sufficient):

   ```bash
   python3 -c "
   import json
   with open('synthetic_corpus.json', 'w') as f:
       for i in range(50000):
           json.dump({'text': 'The quick brown fox ' * 100}, f)
           f.write('\n')
   "
   ```

3. Clone Megatron-DeepSpeed and preprocess:

   ```bash
   git clone https://github.com/microsoft/Megatron-DeepSpeed /fsx/deepspeed/Megatron-DeepSpeed

    enroot start --rw /fsx/apps/deepspeed.sqsh \
    python3 /fsx/deepspeed/Megatron-DeepSpeed/tools/preprocess_data.py \
       --input synthetic_corpus.json \
       --output-prefix BookCorpusDataset_text_document \
       --vocab-file gpt2-vocab.json \
       --merge-file gpt2-merges.txt \
       --tokenizer-type GPT2BPETokenizer \
       --workers 16 --append-eod
   ```

### Running

Submit the best-performing configuration (TP=8, PP=8, ZeRO-0, fusions enabled):

```bash
make train
# or equivalently:
sbatch --partition=dev --nodes=8 \
    --export=ALL,TP=8,PP=8,ZERO_STAGE=0,ENABLE_FUSIONS=1,CONFIG_NAME=best_fused_tp8_pp8 \
    gpt/slurm/pretrain_gpt_103b.sbatch
```

Override parallelism settings for custom configurations:

```bash
sbatch --nodes=8 \
    --export=ALL,TP=8,PP=4,ZERO_STAGE=1,MICRO_BATCH_SIZE=2,CONFIG_NAME=my_config \
    gpt/slurm/pretrain_gpt_103b.sbatch
```

#### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TP` | 8 | Tensor parallel size |
| `PP` | 2 | Pipeline parallel size (best throughput with PP=8, see `make train`) |
| `ZERO_STAGE` | 1 | DeepSpeed ZeRO stage (0, 1, 2, or 3) |
| `MICRO_BATCH_SIZE` | 1 | Per-GPU micro batch size |
| `GLOBAL_BATCH_SIZE` | 64 | Global batch size |
| `SEQ_LENGTH` | 2048 | Sequence length |
| `ENABLE_FUSIONS` | 0 | Set to 1 to enable kernel fusion ops |
| `USE_ACTIVATION_CHECKPOINTING` | 0 | Set to 1 for activation checkpointing |
| `USE_OVERLAP_COMM` | 0 | Set to 1 to overlap communication with compute |
| `TRAIN_ITERS` | 50 | Number of training iterations |
| `CONFIG_NAME` | baseline | Label for this configuration |

### Best practices

The following recommendations are based on extensive parameter sweeps across parallelism strategies, ZeRO stages, NCCL flags, and memory optimizations:

**Parallelism strategy:**

- **Maximize pipeline parallelism** (PP) alongside tensor parallelism (TP) for best throughput. For an 8-node cluster with 8 GPUs per node, TP=8 with PP=8 is optimal.
- **Enable kernel fusion ops** (`ENABLE_FUSIONS=1`) for a significant throughput improvement over the non-fused baseline. This enables masked-softmax, bias-gelu, bias-dropout, and gradient-accumulation fusions.
- **ZeRO-0 outperforms ZeRO-1** when the data-parallel group size is small (e.g., DP=1 with TP=8/PP=8). ZeRO-1's allreduce overhead is not amortized.

**ZeRO-2 and ZeRO-3:**

- ZeRO-2 and ZeRO-3 are **incompatible with pipeline parallelism** in Megatron-DeepSpeed. The sbatch script automatically sets `PP=1` and adds `--no-pipeline-parallel` when `ZERO_STAGE >= 2`.
- ZeRO-3's parameter partitioning **enables lower TP values** that ZeRO-2 cannot fit in memory (e.g., TP=4 works with ZeRO-3 but OOMs with ZeRO-2).
- **Increasing micro-batch size** (e.g., `MICRO_BATCH_SIZE=2`) substantially improves throughput for ZeRO-2 and ZeRO-3 configurations.
- `overlap_comm` provides only marginal improvement (~2%) with ZeRO-3.

**NCCL and networking:**

- NCCL environment flag variations (buffer sizes, chunk sizes, min channels) have **negligible impact** on throughput (~1% range). The defaults in the sbatch script are well-tuned.
- **Do not set `NCCL_ALGO=Tree`** on EFA-based clusters -- it causes hangs. Let the NCCL tuner plugin (`libnccl-ofi-tuner.so`) choose the algorithm automatically.
- **Do not set `NCCL_PROTO` or `FI_EFA_FORK_SAFE`** -- these are not needed and can cause issues.

**Memory:**

- `PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True` is set by default in the sbatch script. Note the **capital T** is required in pytorch:25.04 containers; lowercase `true` causes a `RuntimeError`.
- Sequence length 4096 exceeds available HBM even with TP=8/PP=2 on B200 (178GB per GPU). Use seq=2048 for this model size.

### Parsing results

After training completes, parse the Slurm logs into benchmark JSON using `gpt/parse_results.py`:

```bash
# Single log file
python3 gpt/parse_results.py --log-file logs/deepspeed-pretrain-103b_123.out --config-name my_config

# Multiple jobs tracked in a CSV
python3 gpt/parse_results.py --jobs-csv sweep_results/sweep_jobs.csv --output-dir sweep_results
```

### Known issues

- **torchrun shebang**: The container's `torchrun` may have a shebang pointing to the wrong Python version. The sbatch script uses `python3 -m torch.distributed.run` as a workaround.
- **`expandable_segments` case sensitivity**: Must use `expandable_segments:True` (capital T) in pytorch:25.04-py3. Lowercase causes a `RuntimeError`.
- **NCCL Tree algorithm**: Incompatible with EFA topology -- causes hangs. Do not set `NCCL_ALGO=Tree`.
- **Sequence parallelism**: Incompatible with pipeline parallelism (PP>1) in this Megatron-DeepSpeed version.

## 2. QLoRA Fine-tuning (Qwen3-8B)

Fine-tune [Qwen3-8B](https://huggingface.co/Qwen/Qwen3-8B) using QLoRA (4-bit quantization + LoRA adapters) with DeepSpeed ZeRO-2 or ZeRO-3. Supports deployment on SageMaker HyperPod with both EKS and Slurm orchestrators, including MIG GPU partitioning and automatic checkpoint resume.

The QLoRA use case has its own container (`qlora/Dockerfile`) optimized for the same infrastructure best practices (EFA 1.47, NCCL 2.29.3, GDRCopy 2.5.1).

See [`qlora/README.md`](qlora/README.md) for full instructions.

## 3. Llama2 Fine-tuning (Megatron-DeepSpeed)

Fine-tune Llama2 from HuggingFace weights using Megatron-DeepSpeed. Includes weight conversion from HuggingFace to Megatron format and fine-tuning on the Stanford Alpaca dataset. Uses the shared container image (`0.deepspeed.dockerfile`).

See [`examples_megatron_deepspeed/finetune_hf_llama/README.md`](examples_megatron_deepspeed/finetune_hf_llama/README.md) for full instructions.
