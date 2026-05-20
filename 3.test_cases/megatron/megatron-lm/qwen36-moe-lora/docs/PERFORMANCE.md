# Performance notes

Observed on 2× `ml.p5e.48xlarge` (16× H200 141 GB) during the 4,200-iteration
reference run. Container: `nvcr.io/nvidia/nemo:26.04` (Megatron-Bridge 0.4.0rc0,
Megatron-Core 0.17.0rc0, NeMo 26.04).

## Training throughput

| Metric | Value |
|---|---|
| Wall-clock, 4,200 iterations | 2h 12min |
| Step time (average) | 1.73 s/step |
| Step time (range) | 1.5-2.2 s |
| Tokens per step | 98,304 (global_batch 48 × seq 2048) |
| Total tokens trained | 413 M |
| Epochs over 58.8k train samples | 3.43 |
| Per-GPU throughput (avg) | ~77 MODEL TFLOP/s |
| Aggregate throughput | ~1.2 PFLOPS |
| H200 peak bf16 | 990 TFLOPS |
| Model FLOPs utilization (MFU) | ~7.7% |

MFU is dominated by MoE all-to-all synchronization, not matrix-multiplication
throughput, which is typical for expert-parallel training. Power draw was
200-230 W per GPU (of 700 W TDP) — compute-light, collective-bound.

## Memory usage

Per GPU during steady-state training (sampled via `nvidia-smi`):

| Item | Observed |
|---|---|
| HBM used per GPU | 56-68 GB |
| HBM available per GPU (H200) | 141 GB |
| Utilization | 40-48% |
| Free per GPU | 70-80 GB |

We were **not** memory-constrained. Two levers for higher utilization in a
follow-on run:

- `MICRO_BS=3 → 6` should approximately halve step time
- `SEQ_LENGTH=2048 → 4096` increases arithmetic intensity per token

Both fit within the observed memory headroom. QLoRA (4-bit quantization) is
explicitly **not** needed — the base model fits comfortably in bf16.

## Parallelism topology

```
16 ranks = TP(2) × PP(1) × EP(4) × DP(2)
```

With Megatron's default rank-ordering (`tp-ep-dp`, TP innermost), the 16 ranks
map to the two nodes as:

```
Node A (ranks 0-7)                Node B (ranks 8-15)
  rank 0-6 (even): EP group #1      rank 8-14 (even): EP group #3
  rank 1-7 (odd):  EP group #2      rank 9-15 (odd):  EP group #4
```

Each EP group holds all 256 experts sharded across 4 ranks (64 experts per
rank). EP groups #1 and #2 are TP twins on node A; #3 and #4 are TP twins on
node B. EP groups #{1,3} and #{2,4} are DP replicas — they process different
training examples and sync gradients at step end.

### What runs over NVLink vs EFA

| Collective | Axis | Path | Observed |
|---|---|---|---|
| Attention forward/backward | TP | intra-node NVLink | high bandwidth, low latency |
| MoE token dispatch (all-to-all) | EP | **intra-node NVLink** | fits in one node per EP group |
| MoE token combine (all-to-all) | EP | **intra-node NVLink** | same |
| Gradient all-reduce | DP | **inter-node EFA GDRDMA** | confirmed in NCCL logs |

### Making MoE all-to-all actually cross EFA

The reference configuration keeps MoE a2a intra-node. To exercise inter-node
MoE all-to-all (e.g., for an EFA stress benchmark), set `EP × TP > GPU_PER_NODE`
(i.e., 8 on p5e). Options:

- `TP=1, EP=16, DP=1` on 2× p5e — one EP group spans both nodes
- `TP=2, EP=8, DP=1` on 2× p5e — same span via Megatron rank-order override
- Scale to 4 nodes with `EP=16, DP=2` — EP group must cross

The base checkpoint has to be reconverted (`./scripts/3.convert-to-bridge.sh`)
to match the new sharding.

## Router load imbalance

Sampled GPU utilization per rank during steady-state (16 ranks):

| Range | Count |
|---|---|
| 90-100% | 2-3 ranks |
| 60-89% | 5-6 ranks |
| 30-59% | 3-4 ranks |
| 0-29% | 1-2 ranks |

This variance is the MoE "heavy expert" pattern — on any given step some
experts receive many tokens, others few. The collective barrier at each MoE
layer's all-to-all syncs everything to the slowest rank. `moe_aux_loss_coeff`
(0.001 default in the Qwen3.5-VL recipe) is the regularizer that drives the
router toward balance; raising to 0.01 typically tightens the distribution at
a small loss-quality cost.

## Tokenizer and model sizes

| | Value |
|---|---|
| Base weights (bf16, full) | 70 GB |
| Bridge distcp checkpoint | 68 GB (sharded TP=2, EP=4) |
| LoRA adapter (bf16, rank 64 on attention only) | 108 MB |
| HF tokenizer vocab (real) | 248,077 tokens |
| HF tokenizer vocab (padded to multiple for TP) | 248,320 |

The adapter-to-base ratio is ~1:650 — this is what LoRA buys: serving many
specialized variants of the same base model with tiny incremental storage.
