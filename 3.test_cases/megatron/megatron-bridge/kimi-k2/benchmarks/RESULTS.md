<!-- Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved. -->
<!-- SPDX-License-Identifier: MIT-0 -->

# Kimi-K2 UCCL-EP vs NCCL all-to-all — Benchmark Results

Results template for the MoE token-dispatcher A/B: UCCL's EFA-native DeepEP
drop-in (expert-parallel all-to-all over EFA) vs the stock NCCL all-to-all token
dispatcher, for 256-GPU (32x p6-b300) Kimi-K2 / DSV3-class MoE SFT.

All measured cells are `TBD` until the two harness scripts are run; see
[How to fill this in](#how-to-fill-this-in). The only toggle that changes between
arms is `MOE_DISPATCHER` (`alltoall` -> baseline, `deepep` -> UCCL-EFA treatment);
everything else (model, data, seq length, global batch, precision, parallelism
TP8/EP32/PP8/DP4, seed, image, FSx mounts, EFA env, and the
`MOE_A2A_OVERLAP` flags) is held fixed within a run.

## Tier-A — EFA comm microbench (model-free)

Source: `0.comm-microbench.sh`. UCCL `ep/bench/test_internode.py` (NORMAL/training
kernels) for the DeepEP dispatch/combine numbers; nccl-tests `alltoall_perf` for the
indicative NCCL baseline. Run on the currently-active 8-node B300 block `cb-142bf8f5`
(`cr-02dc459aadea76871`); EP=32 spans 4 nodes = target EP degree. MoE shape:
4096 tokens, hidden 7168, topk 8, 384 experts.

Indicative only, not apples-to-apples: `alltoall_perf` is uniform fixed-size A2A,
while UCCL is the MoE token-routing dispatch/combine pattern (variable per-rank,
permute/unpermute). This bounds EFA headroom; the clean dispatcher delta is Tier-B.

| metric                         | hardware / transport         | EP | value (TBD)        |
|--------------------------------|------------------------------|----|--------------------|
| UCCL-EP dispatch BW (normal)   | p6-b300 + 16x400G EFA        | 32 | TBD GB/s (TBD us)  |
| UCCL-EP combine BW (normal)    | p6-b300 + 16x400G EFA        | 32 | TBD GB/s (TBD us)  |
| UCCL-EP dispatch latency       | p6-b300 + 16x400G EFA        | 32 | TBD us             |
| UCCL-EP combine latency        | p6-b300 + 16x400G EFA        | 32 | TBD us             |
| nccl-tests alltoall_perf busbw | p6-b300 + 16x400G EFA        | 32 | TBD GB/s           |

> nccl-tests busbw is the peak over the swept message-size range (~4 KB .. 1 GB);
> record the message size at which the peak occurs alongside the value.

## Tier-B — end-to-end Megatron step (256 GPUs)

Source: `1.run-ab-dispatcher.sh`. Same PyTorchJob run twice, changing only
`MOE_DISPATCHER`, per `MOE_A2A_OVERLAP` mode. Needs the full 256-GPU config ->
32-node block `cb-4ff6b84d` (`cr-04be19500f13f4a35`, active
2026-05-31T11:30Z .. 2026-06-01T11:30Z). Drop the first `WARMUP_ITERS` (default 20)
measured iters; report **medians** over `MEASURE_ITERS` (default 50).

- **overlap=on** is the realistic deployment number; A2A is mostly hidden behind
  compute (Megatron 1F1B hides up to ~93%). Expect the `delta` here to be small —
  that is the correct, expected result, not a benchmark failure.
- **overlap=off** is dispatcher isolation; A2A is fully exposed (the "up to 60% of
  step" regime). It is the upper bound on the dispatcher's contribution — never
  present it as the deployment delta.

| overlap | metric                         | alltoall | deepep | delta |
|---------|--------------------------------|----------|--------|-------|
| on      | elapsed time per iteration (ms) | TBD      | TBD    | TBD   |
| on      | throughput per GPU (TFLOP/s/GPU) | TBD     | TBD    | TBD   |
| on      | MFU [^mfu]                     | TBD      | TBD    | TBD   |
| on      | derived tokens/s [^tps]        | TBD      | TBD    | TBD   |
| off     | elapsed time per iteration (ms) | TBD      | TBD    | TBD   |
| off     | throughput per GPU (TFLOP/s/GPU) | TBD     | TBD    | TBD   |
| off     | MFU [^mfu]                     | TBD      | TBD    | TBD   |
| off     | derived tokens/s [^tps]        | TBD      | TBD    | TBD   |

[^mfu]: MFU = `throughput per GPU (TFLOP/s/GPU)` / B300 BF16 peak TFLOP/s.
[^tps]: tokens/s is **not** a printed Megatron label; derive it as
    `global_batch x seq_len / iter_time_s`. There is no per-op dispatch/combine
    timer in the iteration log (NVTX/Nsight only).

## Expected / reference table (verbatim from spec)

Every reference number is labeled by hardware + transport + source tier. None of
them is a DeepEP-on-EFA-vs-NCCL-alltoall *training* number — that is exactly what
Tier-B produces.

<!-- markdownlint-disable MD013 -->

> **All reference numbers below are labeled by hardware + transport + source tier. None of them is a DeepEP-on-EFA-vs-NCCL-alltoall *training* number — that measurement does not exist in the literature and is exactly what Tier-B produces.** EFA numbers come only from UCCL (the drop-in); DeepEP's own tables are InfiniBand. Tier: T1 = official docs/source/paper, T2 = blog cross-checkable.

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

Pins: DeepEP V1 README `e0eaaf94` (2025-04-21); V2 `b306af06` (2026-04-29); UCCL ep/README `0dc87eb3`; UCCL-EP arXiv:2512.19849v2 (2026-01-22); UCCL blog 2025-10-27; Megatron-Core MoE arXiv:2603.07685; DeepSeek-V3 arXiv:2412.19437; AWS p6-b300 blog 2025-11-18.

<!-- markdownlint-enable MD013 -->

## Honest bottom line

The communication-layer delta from swapping the NCCL all-to-all dispatcher for the
DeepEP/UCCL-over-EFA drop-in can be large in microbenchmarks (Tier-A), but the
end-to-end training delta (Tier-B) is most likely modest — plausibly single-digit
to low-double-digit percent on a well-overlapped baseline — and must be measured,
not quoted. Key caveats baked into the reference table above:

- DeepEP's own headline numbers (153/158 GB/s NVLink, ~59 GB/s EP32 internode, V2's
  726/740 GB/s on Blackwell) are H800/SM100 + ConnectX-7 **InfiniBand**, and stock
  DeepEP cannot run on EFA at all.
- The only EFA evidence is **UCCL's** EFA-native drop-in (B200+EFAv4 ~53/57 GB/s
  dispatch/combine at EP32; H200+EFAv3 54/43 GB/s) — measured on B200/H200, **not
  B300**.
- There is **no published DeepEP-on-EFA-vs-NCCL-alltoall training number anywhere**:
  the "2.1x" is UCCL vs PPLX (not NCCL), "+40%" is SGLang inference (not training),
  "+32%" is TorchTitan on InfiniBand (not EFA/Megatron), and "+7–45%" is AMD
  MI300X+Broadcom vs RCCL (wrong platform).
- Megatron's 1F1B overlap hides up to ~93% of all-to-all latency; the "up to 60% of
  step is A2A" figure is the overlap-OFF ceiling. p6-b300's 16x400G EFA
  (6.4 Tbps/node) is 2x the per-GPU bandwidth of every published testbed, which
  further compresses the exposed (post-overlap) comm.

Therefore: report **Tier-B overlap=on as the deployment number** (expected small)
and **overlap=off as the dispatcher-isolation upper bound** (never the deployment
delta). A small overlap=on delta is the correct, expected result.

## How to fill this in

1. **Tier-A** — run `0.comm-microbench.sh` on block `cb-142bf8f5`. It runs UCCL
   `ep/bench/test_internode.py` (NORMAL/training kernels) for dispatch/combine
   BW + latency, and nccl-tests `alltoall_perf` for the indicative NCCL busbw.
   Copy the reported values into the Tier-A table.
2. **Tier-B** — run `1.run-ab-dispatcher.sh` on block `cb-4ff6b84d`. It submits the
   PyTorchJob twice per overlap mode (changing only `MOE_DISPATCHER`), drops the
   first `WARMUP_ITERS` iters, and reports medians over `MEASURE_ITERS` of
   `elapsed time per iteration (ms)` and `throughput per GPU (TFLOP/s/GPU)`.
   Compute MFU and derived tokens/s per the footnotes, then fill the Tier-B table
   (`delta` = deepep vs alltoall within each overlap mode).

**Confounder guard:** assert `NET/OFI Selected Provider is efa` appears in the logs
for every rank of every run. Discard and re-run any run where it does not.
