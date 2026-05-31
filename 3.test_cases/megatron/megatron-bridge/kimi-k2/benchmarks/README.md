<!-- Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved. -->
<!-- SPDX-License-Identifier: MIT-0 -->

# Kimi-K2 MoE: DeepEP/UCCL-over-EFA vs NCCL all-to-all — Benchmark

This harness measures the performance of UCCL's EFA-native **DeepEP drop-in**
(expert-parallel dispatch/combine over AWS EFA) against the standard **NCCL
all-to-all** token dispatcher, for Kimi-K2 / DeepSeek-V3-class fine-grained MoE
training with NVIDIA Megatron-Bridge / Megatron-Core on **32x p6-b300.48xlarge**
(256x B300, 8 GPU/node, 16x 400 Gbps EFAv4 = 6.4 Tbps/node).

## Overview — the A/B (only the dispatcher changes)

The experiment is a strict A/B in which **the only thing that changes is the MoE
token dispatcher**. Everything else — model, data, parallelism, precision, image,
EFA env, and the A2A/EP overlap configuration — is held identical, so any measured
delta is attributable to the dispatcher and not to a confounder.

| arm | dispatcher | what carries dispatch/combine |
|-----|------------|-------------------------------|
| **WITHOUT DeepEP** (baseline) | `moe_token_dispatcher_type="alltoall"` | NCCL all-to-all over EFA (via aws-ofi-nccl) |
| **WITH DeepEP** (treatment) | `moe_token_dispatcher_type="flex"`, `moe_flex_dispatcher_backend="deepep"` | DeepEP kernels; on AWS the `deep_ep` module imported is **UCCL's EFA-native drop-in** (stock NVIDIA DeepEP is NVSHMEM/IBGDA-bound and cannot run on EFA) |

- Model: Kimi-K2 / DSV3-class (384 routed experts, top-8, MLA, hidden 7168).
- Parallelism: **TP=8** (intra-node), **EP=32** (spans 4 nodes), **PP=8**, **DP=4** = 256 GPUs (32 nodes x 8 B300).
- Image: `159553542841.dkr.ecr.us-west-2.amazonaws.com/megatron-bridge-uccl:nemo-25.11.01-uccl-0dc87eb`
- FSx layout: `/fsx/kimi-k2/{hf,mcore,sft-data,sft-output}`; benchmark outputs -> `/fsx/kimi-k2/bench`.
- Cluster: `ml-clusters-shared-us-west-2` (account `159553542841`, `us-west-2`,
  kubectl context `shared-usw2`), kubeflow training-operator PyTorchJob, namespace
  `kimi-k2-bench`.

Scripts in this directory:

| file | tier | what it does |
|------|------|--------------|
| `0.comm-microbench.sh` | Tier-A | model-free comm microbench (UCCL ep/bench vs nccl-tests `alltoall_perf`) |
| `1.run-ab-dispatcher.sh` | Tier-B | end-to-end Megatron step A/B (renders the template twice per overlap mode, toggling `MOE_DISPATCHER`) |
| `kimi-k2-bench-pytorchjob.yaml-template` | Tier-B | Worker-only PyTorchJob template the Tier-B runner renders per arm via `envsubst` |
| `RESULTS.md` | — | results sheet; Tier-B rows are appended automatically, Tier-A pasted by hand |

---

## Honest bottom line (read this first)

For our 256-GPU (32x p6-b300) Kimi-K2 / DSV3-class MoE training A/B, the honest
expectation is: the *communication-layer* delta from swapping the NCCL all-to-all
token dispatcher for the DeepEP/UCCL-over-EFA drop-in can be large in
microbenchmarks, but the *end-to-end training* delta is most likely modest —
plausibly single-digit to low-double-digit percent on a well-overlapped baseline —
and must be measured, not quoted.

The critical caveats, all of which the reference table below preserves:

- **DeepEP's own headline numbers are InfiniBand, not EFA.** 153/158 GB/s NVLink,
  ~59 GB/s EP32 internode, and V2's 726/740 GB/s on Blackwell are all H800/SM100 +
  ConnectX-7 **InfiniBand**, and stock DeepEP cannot run on EFA at all. The EFA
  delta depends entirely on **UCCL's** EFA-native drop-in.
- **The only EFA evidence is UCCL's own B200/H200 numbers** (B200 + EFAv4:
  ~53 GB/s dispatch / ~57 GB/s combine at EP32; H200 + EFAv3: 54/43 GB/s) — on
  B200/H200, **not B300**. No published B300 EFA number exists.
- **There is no published DeepEP-on-EFA-vs-NCCL-alltoall training number
  anywhere.** The "2.1x" is UCCL vs PPLX (not NCCL); "+40%" is SGLang inference
  (not training); "+32%" is TorchTitan on InfiniBand (not EFA/Megatron); "+7–45%"
  is AMD MI300X + Broadcom vs RCCL (wrong platform).
- **The decisive bound:** Megatron's 1F1B overlap hides up to ~93% of all-to-all
  latency, and the "up to 60% of step is A2A" figure is the overlap-OFF ceiling.
  The realized training gain is bounded by the *exposed* (post-overlap) comm,
  further compressed because p6-b300's 16x400G EFA (6.4 Tbps/node) is 2x the
  per-GPU bandwidth of every published testbed.

Report Tier-B **overlap=on** as the deployment number and **overlap=off** as the
dispatcher-isolation upper bound. A small overlap=on delta is the correct,
expected result — not a benchmark failure.

---

## Expected / reference table

> **All reference numbers below are labeled by hardware + transport + source tier.
> None of them is a DeepEP-on-EFA-vs-NCCL-alltoall *training* number — that
> measurement does not exist in the literature and is exactly what Tier-B
> produces.** EFA numbers come only from UCCL (the drop-in); DeepEP's own tables
> are InfiniBand. Tier: T1 = official docs/source/paper, T2 = blog cross-checkable.

| metric | without-DeepEP / baseline | with-DeepEP / UCCL-EFA | delta | hardware / transport | source + tier | caveat |
|--------|---------------------------|------------------------|-------|----------------------|---------------|--------|
| EP32 internode dispatch BW (normal kernels) | — | 53 GB/s (2072 us) | — | B200 + 8x400G **EFAv4** (p6-b200) | UCCL ep/README @0dc87eb3 — **T1** | closest published EFA training proxy; B200 not B300; 1 NIC/GPU vs target 2 |
| EP32 internode combine BW (normal kernels) | — | 57 GB/s (3724 us) | — | B200 + EFAv4 | UCCL ep/README @0dc87eb3 — **T1** | BF16 combine, ~1.8x dispatch latency; forward only (no backward published) |
| EP32 internode dispatch / combine | — | 54 / 43 GB/s | — | H200 + 16x200G **EFAv3** (p5en) | UCCL blog 2025-10-27 — **T1** | combine collapses to 18 GB/s @ EP16; 2-NIC/GPU topology like target but older GPU |
| dispatch+combine throughput | **PPLX** (best EFA EP solution) | up to **2.1x** PPLX | 2.1x | H200/B200 + EFA | UCCL-EP arXiv:2512.19849v2 — **T1** | **baseline is PPLX, NOT NCCL**; per-kernel, not training; "up to"/batch-dependent |
| EP32 dispatch / combine latency vs PPLX | PPLX | 2.3x / 1.1–1.5x lower | — | H200 + EFAv3 | arXiv:2512.19849v2 — **T1** | medium/large batch only; PPLX wins at ≤128 tokens (EFA small-msg firmware limit) |
| EP32 internode dispatch / combine | — | 59 / 60 GB/s | — | H800 + CX7 **InfiniBand** | DeepEP README @e0eaaf94 — **T1** | **IB NOT EFA**; the canonical "DeepEP internode" cite; stock DeepEP can't run on EFA |
| intranode dispatch / combine | — | 153 / 158 GB/s | — | H800 **NVLink** | DeepEP README @e0eaaf94 — **T1** | **NVLink**; ~99% of 160 GB/s ceiling; not internode, not EFA |
| V2 intranode dispatch / combine (Blackwell) | — | 726 / 740 GB/s | — | SM100 **NVLink** (IB testbed) | DeepEP README @b306af06 — **T1** | closest Blackwell proxy but **logical BW** (incl. local traffic), NVLink not EFA |
| SGLang prefill throughput @ EP32 (Qwen3-235B) | 44K tok/s (**NCCL**) | 62K tok/s (UCCL) | **+40%** | H200 + EFAv3 | arXiv:2512.19849v2 Fig13 — **T1** | **inference, not training**; only NVIDIA+EFA-vs-NCCL point; large partly because NCCL can't scale at large EP |
| DeepSeek-V3 training tok/s (DeepEP A/B) | 651 (BF16 EP) | 859 (+DeepEP); 918 (+MXFP8) | **+32%** (DeepEP-only) | B200, NVLink + **IB** | TorchTitan blog — **T2** | **IB not EFA; TorchTitan not Megatron**; +41% headline includes MXFP8 |
| DeepSeek-V3 training tok/s vs RCCL | RCCL | +7% to +45% tok/s | — | AMD MI300X + Broadcom Thor-2 | arXiv:2512.19849v2 Fig14 — **T1** | **AMD, not EFA/NVIDIA/NCCL**; 379B/32-layer downscaled; only end-to-end training A/B that exists |
| A2A share of step (unoptimized) | — | — | up to 60% | DSV3 cross-node EP (NVIDIA) | Megatron-Core arXiv:2603.07685 — **T1** | **overlap-OFF ceiling**, not a realized gain; sets max headroom only |
| A2A latency hidden by 1F1B overlap | — | — | up to 93% | Megatron-Core | Megatron-LM README — **T1** | the decisive bound: shrinks the realized end-to-end training delta to the *exposed* residual |
| compute-to-comm ratio (cross-node EP A2A) | — | — | ~1:1 before overlap | 2048x H800, NVLink+IB | DeepSeek-V3 arXiv:2412.19437 §3.2.1 — **T1** | A2A ≈ compute pre-overlap; DualPipe then drives it to near-zero exposed |

Pins: DeepEP V1 README `e0eaaf94` (2025-04-21); V2 `b306af06` (2026-04-29); UCCL
ep/README `0dc87eb3`; UCCL-EP arXiv:2512.19849v2 (2026-01-22); UCCL blog
2025-10-27; Megatron-Core MoE arXiv:2603.07685; DeepSeek-V3 arXiv:2412.19437; AWS
p6-b300 blog 2025-11-18.

---

## Methodology

### The single toggle — `MOE_DISPATCHER`

`conf/kimi_k2_sft.py` (owned by another process — **not** edited here) honors one
env var, `MOE_DISPATCHER`:

```python
# conf/kimi_k2_sft.py reads env MOE_DISPATCHER in {"alltoall", "deepep"}:
import os
_disp = os.environ.get("MOE_DISPATCHER", "alltoall")
if _disp == "deepep":
    moe_token_dispatcher_type   = "flex"
    moe_flex_dispatcher_backend = "deepep"   # on AWS the deep_ep module is UCCL's EFA build
else:
    moe_token_dispatcher_type   = "alltoall"  # NCCL all-to-all over EFA — baseline
```

> `# TODO(validate against image)`: current Megatron main defaults the flex backend
> to `deepep`, but an older path needs `--moe-enable-deepep true` (issue #1721).
> Confirm which the `nemo-25.11.01-uccl-0dc87eb` image requires.
> <https://github.com/NVIDIA/Megatron-LM/blob/main/megatron/core/transformer/moe/README.md>
> <https://github.com/NVIDIA/Megatron-LM/issues/1721>

> On AWS the `deep_ep` Python module imported by the `deepep` backend **must be
> UCCL's EFA-native build**, not stock NVIDIA DeepEP (NVSHMEM/IBGDA-bound, won't
> run on EFA). Megatron only sees the backend string `"deepep"`; which library it
> imports is an image/install concern baked into the `nemo-25.11.01-uccl-0dc87eb`
> image. `# TODO(validate against image)`

### Hold fixed across both arms (confounder control)

Everything except the dispatcher is identical — otherwise you measure a
confounder, not the dispatcher: model, data, seq length, global batch, precision
(FP8 dispatch / BF16 combine), parallelism (TP8/EP32/PP8/DP4), random seed, image,
FSx mounts, EFA env (`FI_PROVIDER=efa`, `FI_EFA_FORK_SAFE=1`), and — **most
decisive** — the **A2A/EP overlap flags** (`--overlap-moe-expert-parallel-comm`,
`--delay-wgrad-compute`). Those flags are gated by `MOE_A2A_OVERLAP`, set
**identically for both arms within a run**, so overlap never differs between
`alltoall` and `deepep`.

Two more env contracts the Tier-B harness sets (config must honor; mark TODO until
verified):

- `MOE_A2A_OVERLAP` in `{on,off}` — gates the overlap flags above; identical
  across arms in a mode. `conf/kimi_k2_sft.py` treats it as ON iff the value ==
  `"on"`. `# TODO(validate against image)`
- `TRAIN_ITERS` — total iterations (warmup + measure). `# TODO(validate against image)`

### overlap=on vs overlap=off — and why overlap=on is the deployment number

Run **both** overlap modes and report both:

- **`overlap=on` — realistic deployment.** A2A is mostly hidden behind compute
  (Megatron 1F1B hides up to ~93% of A2A latency). **This is the number to report
  as the deployment speedup; expect it small.**
- **`overlap=off` — dispatcher isolation.** A2A fully exposed (the "up to 60% of
  step" regime). Upper bound on the dispatcher's contribution; **never present it
  as the deployment delta.**

> `# TODO(validate against image)`: if `--overlap-moe-expert-parallel-comm` is
> dispatcher-incompatible in this Megatron version (supported on only one arm),
> the clean comparison is **`overlap=off` on both arms** — do not let overlap
> differ between arms.

---

## Two measurement tiers (and which capacity block each runs on)

Tier-A is a fast, model-free comm sanity check on the **currently-active 8-node
block**; Tier-B is the real end-to-end answer on the **full 32-node 256-GPU
config**.

### Tier-A — comm microbenchmark (`0.comm-microbench.sh`)

Model-free, runs on the **currently-active 8-node B300 block `cb-142bf8f5`**
(`cr-02dc459aadea76871`). EP=32 = 4 nodes = the target EP degree, so the 8-node
block is sufficient — Tier-A does not need the full 32-node block.

1. **WITH-DeepEP path**: UCCL `ep/bench/test_internode.py` (**NORMAL/training**
   kernels — *not* `test_low_latency.py`, which is the inference/decode path).
   Prints per dispatch and combine: `transmit: X us`, `notify: X us`,
   `BW: X GB/s (RDMA)`, `BW: X GB/s (NVL)`, and a `[tuning] Best
   dispatch/combine` summary. MoE shape: `--num-tokens 4096 --hidden 7168
   --num-topk 8 --num-experts 384` (Kimi-K2 routed expert count; README default is
   256/288 — 384/EP32 = 12 experts/rank). `# TODO(validate against image)` for the
   bench path (`/opt/uccl/ep/bench/test_internode.py`) and its flags — see the
   markers in `0.comm-microbench.sh`.
2. **WITHOUT-DeepEP baseline (indicative)**: nccl-tests `alltoall_perf` swept from
   ~4 KB (≈7 KB FP8 per-token granularity) to 1 GB (bulk-packed per-rank buffer).
   Reports `busbw` (GB/s).

**This comparison is INDICATIVE, not apples-to-apples**: `alltoall_perf` is a
uniform fixed-size all-to-all; UCCL `test_internode.py` is the MoE token-routing
dispatch/combine pattern (variable per-rank, FP8 dispatch + BF16 combine,
permute/unpermute). Use it to bound EFA headroom for the token-dispatch pattern,
not as a clean dispatcher delta. The clean dispatcher delta is Tier-B.

### Tier-B — end-to-end Megatron step (`1.run-ab-dispatcher.sh`)

Needs the full 256-GPU config → **32-node block `cb-4ff6b84d`**
(`cr-04be19500f13f4a35`, active **2026-05-31T11:30Z .. 2026-06-01T11:30Z**).
Verify nodes are Ready before launching:

```bash
kubectl --context shared-usw2 get nodes -l capacity-reservation=4ff6b84d
```

Launches the **same** PyTorchJob (running `conf/kimi_k2_sft.py`) twice, changing
**only** `MOE_DISPATCHER` (and `MOE_A2A_OVERLAP` per mode, identical across arms),
for `TRAIN_ITERS = WARMUP_ITERS + MEASURE_ITERS` steps.

---

## How to run

```bash
cd 3.test_cases/megatron/megatron-bridge/kimi-k2/benchmarks

# Tier-A — model-free comm microbench on the ACTIVE 8-node block (cb-142bf8f5).
# EP=32 = 4 nodes; prints UCCL dispatch/combine vs nccl alltoall_perf busbw.
OUTDIR=/fsx/kimi-k2/bench/tier-a bash 0.comm-microbench.sh

# Tier-B — end-to-end A/B on the 32-node block (cb-4ff6b84d, active 2026-05-31).
# Runs alltoall then deepep, both overlap modes; appends to RESULTS.md.
OUTDIR=/fsx/kimi-k2/bench/tier-b OVERLAP=both bash 1.run-ab-dispatcher.sh

# Realistic-only (faster): just the overlap=on pair — the deployment number.
OUTDIR=/fsx/kimi-k2/bench/tier-b OVERLAP=on bash 1.run-ab-dispatcher.sh
```

Common overrides (env): `CTX`, `NAMESPACE`, `CB_SHORT`, `REPO_URI` (Tier-B image;
Tier-A uses `IMAGE`), `WARMUP_ITERS`, `MEASURE_ITERS`, `GLOBAL_BATCH`, `SEQ_LEN`,
`OVERLAP`, `OUTDIR`. The per-arm `JOB_NAME` is **auto-derived**
(`kimi-k2-bench-<dispatcher>-<overlap>`), not a user override.

> The canonical benchmark output root is `/fsx/kimi-k2/bench`; the examples above
> pass `OUTDIR` explicitly so the documented commands produce that layout. (The
> scripts' built-in `OUTDIR` default differs and is overridable — see the
> open questions for the script owner.)

### The bench manifests

- **Tier-A** (`0.comm-microbench.sh`) emits its manifests **inline**: two jobs
  rendered on the fly (a UCCL ep/bench PyTorchJob and an nccl-tests `alltoall_perf`
  MPIJob) and `kubectl apply`'d. Placeholders are shell-substitutable (`${IMAGE}`,
  `${EP_SIZE}`, `${NNODES}`, `${CB_SHORT}`, MoE-shape vars), so overriding the env
  vars above re-renders the manifest.
- **Tier-B** (`1.run-ab-dispatcher.sh`) renders the **separate template file**
  `kimi-k2-bench-pytorchjob.yaml-template` in this directory. It is a Worker-only
  PyTorchJob (no Master) that runs `conf/kimi_k2_sft.py`. The runner EXPORTs the
  full placeholder set, renders with bare `envsubst < template`, and applies a
  fresh, uniquely-named job per arm — it does **not** patch a pre-existing job.
  Each arm sets these three env values in the rendered manifest:

  ```yaml
  - { name: MOE_DISPATCHER,  value: "alltoall|deepep" }
  - { name: MOE_A2A_OVERLAP, value: "on|off" }
  - { name: TRAIN_ITERS,     value: "<warmup+measure>" }
  ```

  The per-arm `metadata.name` is `${JOB_NAME}` = `kimi-k2-bench-<dispatcher>-<overlap>`
  (e.g. `kimi-k2-bench-deepep-on`); the runner's wait / rank-0-log / cleanup all
  key off that same name. Rank-0 logs come from the `worker-0` pod (label selector
  `training.kubeflow.org/replica-type=worker` + `replica-index=0`).
  `# TODO(validate against image)`: confirm the template's container name
  (`pytorch`) and that the operator labels the rank-0 pod `worker-0`.

### Capacity-block scheduling contract

From `modules/cb-node-group`, the CB managed node group carries taints
`nvidia.com/gpu=true`, `workload=bench`, `capacity-reservation=<short>` and labels
`workload=bench`, `capacity-reservation=<short>`. Both scripts set the matching
`nodeSelector` + `tolerations` and request `vpc.amazonaws.com/efa: 16` per node.

---

## How to read the results

1. **Validate the run (EFA-provider assertion).** Both arms must log
   `NET/OFI Selected Provider is efa` on every rank. If a run fell back to the
   sockets provider, it is comparing a different fabric — **discard it**. The
   Tier-A script greps this line into its comparison block; for Tier-B, grep the
   per-arm logs in `$OUTDIR/<ts>/`.
2. **Drop warmup, report medians.** Drop the first `WARMUP_ITERS` (default 20)
   measured iterations — iter-0 is a Megatron allocator/compile outlier and
   UCCL/DeepEP autotune SM counts on the first dispatch/combine calls — then report
   **medians** over the remaining `MEASURE_ITERS` (default 50) for stability
   against stragglers.
3. **Megatron's iteration timers.**
   - `elapsed time per iteration (ms): X` — printed **always**; primary A/B metric.
   - `throughput per GPU (TFLOP/s/GPU): X` — printed **only with
     `--log-throughput`**; MFU = this ÷ B300 BF16 peak.
     `# TODO(validate against image)`: ensure `--log-throughput` is set.
4. **tokens/s is DERIVED, not printed.** `tokens/sec` is **not** a Megatron label
   (it appears only on the RL path). The harness derives it:
   `tokens/s = global_batch × seq_len ÷ iter_time_s`. Grepping for a tokens/s
   label scrapes nothing.
5. **There is no per-op dispatch/combine timer.** The MoE layer only wraps
   dispatch/combine in **NVTX ranges** (Nsight). `--timing-log-level` does not
   break them out and `--moe-per-layer-logging` covers only aux/z-loss. The
   per-iteration A/B relies on iter-time + TFLOP/s/GPU; for a per-op breakdown,
   profile with Nsight.
6. **Read each tier for what it is.** Tier-A bounds EFA comm headroom for the
   dispatch/combine pattern (indicative). Tier-B **`overlap=on`** is the
   deployment delta — report this as *the* number; Tier-B **`overlap=off`** is the
   dispatcher-isolation upper bound — report alongside, labeled, never as the
   deployment delta. When comparing measured EFA deltas against the reference
   table above, flag any case where a measured EFA number is placed next to an IB
   number without a transport label.

---

## Caveats

- **p6-b300 has 2x the per-GPU bandwidth of every published testbed → expect a
  small overlap=on delta.** 16x400G EFA = 6.4 Tbps/node is double the per-GPU
  bandwidth of UCCL's B200 (8x400G) and H200 (16x200G) testbeds. That lowers the
  exposed-comm fraction below any reference, biasing the realistic `overlap=on`
  delta toward the low end. A small delta is the **correct, expected** result, not
  a benchmark failure — the dispatcher swap's value shows up most when the baseline
  is comm-bound (overlap off, or EP scaled wider than 32).
- **B300 has no published EFA number.** Every EFA reference here is UCCL on B200 or
  H200; there is no B300 + EFA dispatch/combine number in the literature. Treat
  UCCL's B200 + EFAv4 numbers as the proxy and remember the second NIC per GPU on
  p6-b300 is unmodelled by any published measurement.
- **Indicative, not apples-to-apples (Tier-A).** `alltoall_perf` is uniform A2A;
  UCCL is the MoE token-routing pattern. Tier-A bounds EFA headroom; the clean
  dispatcher delta is Tier-B.
- **Every reference number is transport-labeled; only Tier-A/B rows are
  measured-EFA.** Do not copy an InfiniBand (or inference, or PPLX/RCCL-baseline,
  or non-Megatron) number into a measured-EFA row.
