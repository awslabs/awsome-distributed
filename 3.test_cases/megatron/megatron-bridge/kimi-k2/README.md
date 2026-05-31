<!-- Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved. -->
<!-- SPDX-License-Identifier: MIT-0 -->

# Kimi K2 Full-Parameter SFT with Megatron-Bridge + UCCL-EP over EFA

This test case provides a reproducible recipe for **full-parameter supervised fine-tuning
(SFT)** of [Kimi K2](https://huggingface.co/moonshotai/Kimi-K2-Base) (Moonshot AI's
1.04T-parameter Mixture-of-Experts model) on Amazon EKS, using
[NVIDIA Megatron-Bridge](https://github.com/NVIDIA-NeMo/Megatron-Bridge) for the training loop
and [UCCL-EP](https://github.com/uccl-project/uccl) for the expert-parallel all-to-all over
**AWS EFA**.

## Overview

Kimi K2 is a DeepSeek-V3-family MoE model: 1.04T total parameters with 32B active per token,
384 routed experts (8 selected per token) plus 1 shared expert, and Multi-head Latent Attention
(MLA). Training it requires expert parallelism (EP), which moves tokens between experts that
live on different GPUs/nodes through an **all-to-all** dispatch/combine. On NVIDIA reference
stacks that all-to-all is handled by [DeepEP](https://github.com/deepseek-ai/DeepEP), which is
built on **NVSHMEM and InfiniBand verbs** and therefore does **not** run on AWS EFA.

The crux of this test case is replacing DeepEP with UCCL's EFA-native implementation **without
patching Megatron-Core**:

- Megatron-Bridge drives SFT through Megatron-Core's `flex` token dispatcher with the `deepep`
  backend. Megatron-Core resolves that backend by importing a top-level Python module named
  `deep_ep`.
- UCCL ships a **shadow `deep_ep` module** (`/opt/uccl/ep/deep_ep_wrapper`) that installs a
  top-level package also named `deep_ep`. Because it is installed into `site-packages`,
  `import deep_ep` resolves to UCCL's EFA RDMA implementation instead of NVIDIA DeepEP.
- The result: Megatron-Core's MoE dispatcher calls the same `deep_ep` API symbols it always
  does, but the bytes go over EFA via UCCL + GDRCopy instead of over IB verbs via NVSHMEM.

> **This is a research/validation recipe, not a production-blessed path.** UCCL's `deep_ep`
> drop-in has been exercised primarily for vLLM **inference**. The training **combine-backward**
> path is not yet independently proven at this scale. Treat every gate in
> [Known edge cases](#known-edge-cases--validation-gates) as a hard stop.

## Architecture: the integration chain

The call chain that must hold end to end, from the SFT entry point down to the wire:

```text
Megatron-Bridge finetune()                # src/megatron/bridge/training/finetune.py
  -> ConfigContainer                       # bf16=True, use_distributed_optimizer=True
       moe_token_dispatcher_type="flex"
       moe_flex_dispatcher_backend="deepep"
       moe_enable_deepep=True
  -> Megatron-Core MoE flex dispatcher     # deepep backend
       import deep_ep                       # <-- resolves to the UCCL SHADOW module
  -> UCCL deep_ep wrapper                   # /opt/uccl/ep/deep_ep_wrapper (top-level deep_ep)
  -> UCCL-EP kernels                        # /opt/uccl/ep, built for sm_103 (B300)
  -> libfabric / EFA provider + GDRCopy    # FI_PROVIDER=efa, FI_EFA_USE_DEVICE_RDMA=1
  -> 16x EFA interfaces per p6-b300 node    # vpc.amazonaws.com/efa: 16
```

Everything above `import deep_ep` is stock NGC software (Megatron-Bridge, Megatron-Core,
TransformerEngine from `nvcr.io/nvidia/nemo:25.11.01`). Everything below it is the EFA fabric.
The shadow module is the single hinge that swaps the transport.

## Prerequisites

| Requirement | Value / Notes |
|-------------|---------------|
| EKS cluster | `ml-clusters-shared-us-west-2` (account `159553542841`, region `us-west-2`) |
| Node group | `cb-4ff6b84d` — 32x `p6-b300.48xlarge` (256x B300, 8 GPU/node, capacity block) |
| GPU | NVIDIA B300, 288 GB HBM3e, compute capability `sm_103` |
| EFA | 16 EFA interfaces per node (1 of 17 net cards is ENA-only) |
| Shared storage | FSx for Lustre, mounted at `/fsx` via a PVC (`fsx-claim`); budget 4-5 TB |
| Registry | ECR `159553542841.dkr.ecr.us-west-2.amazonaws.com` (us-west-2) |
| Operators | [Kubeflow Training Operator](https://www.kubeflow.org/docs/components/training/) (PyTorchJob), NVIDIA + EFA device plugins |
| Scheduler | Default scheduler works; KAI gang scheduling (PodGroup) is OPTIONAL/opt-in for all-or-nothing 32-node start (see `kubernetes/README.md`) |
| Tooling | Docker for the build, `kubectl` + `aws` CLI configured for the workload account |

Confirm cluster/account before any mutation:

```bash
aws sts get-caller-identity   # expect Account 159553542841
kubectl config current-context
```

### Node taints to tolerate

The capacity-block nodes carry three taints; the PyTorchJob pod template must tolerate all of
them and pin the instance type:

```yaml
tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
  - key: workload
    value: bench
    operator: Equal
    effect: NoSchedule
  - key: capacity-reservation
    operator: Exists
    effect: NoSchedule
nodeSelector:
  node.kubernetes.io/instance-type: p6-b300.48xlarge
```

## Step-by-step

> **First build the shared environment image.** The Dockerfile and its build +
> single-node sanity scripts are **model-agnostic** and live one level up at the
> library root. Before the model-specific steps below, run library steps 1–2 from
> [`../`](../README.md):
> ```bash
> cd ..                      # 3.test_cases/megatron/megatron-bridge
> bash 1.build-and-push.sh   # build & push megatron-bridge-uccl:nemo-25.11.01-uccl-0dc87eb
> bash 2.sanity-singlenode.sh   # inside the image, on one p6-b300 node (do NOT skip)
> cd kimi-k2
> ```

The model-specific helper scripts below are numbered in usage order. Run them from
this directory.

### 1. Convert HF Kimi K2 to a Megatron-Core checkpoint

Kimi K2's HF weights ship block-FP8 (~1 TB). Full SFT runs in BF16, so the weights are
dequantized to BF16 (~2 TB) and converted to a Megatron-Core distributed checkpoint with
Megatron-Bridge's `AutoBridge`. `1.convert-checkpoint.sh` wraps Megatron-Bridge's conversion
entry point:

```bash
# under the hood (Megatron-Bridge examples/conversion/convert_checkpoints.py):
python examples/conversion/convert_checkpoints.py import \
  --hf-model /fsx/kimi-k2/hf \
  --megatron-path /fsx/kimi-k2/mcore \
  --torch-dtype bfloat16 \
  --trust-remote-code
```

This is a large, multi-hour, memory-heavy job; run it on a node with the FSx mount and enough
host RAM (p6-b300 nodes have 4 TB). Budget 4-5 TB on FSx for the HF + BF16 + MCore copies.

> `AutoBridge.from_hf_pretrained(...).to_megatron_provider()` is the programmatic equivalent.
> See [Open questions](#open-questions) — the exact dequantize-then-import flow for a block-FP8
> 1T MoE checkpoint should be validated against the built image.

### 2. Create the SFT-config ConfigMap

The shared env image is model-agnostic and does **not** bake in any SFT config. The
PyTorchJob mounts `conf/kimi_k2_sft.py` at `/workspace/conf` from a ConfigMap, which you
create from the file in this directory:

```bash
kubectl create configmap kimi-k2-sft-conf \
  --from-file=kimi_k2_sft.py=conf/kimi_k2_sft.py -n <namespace>
```

Re-create it (`--dry-run=client -o yaml | kubectl apply -f -`) whenever you edit the conf.
See [`kubernetes/README.md`](kubernetes/README.md) for details.

### 3. Deploy the 32-node PyTorchJob

Deployment is **not** a script — render the manifest template with `envsubst` and apply it:

```bash
envsubst < kubernetes/manifests/kimi-k2-sft-pytorchjob.yaml-template | kubectl apply -f -
```

This applies the etcd `Service` + `Deployment` and the `kubeflow.org/v1` PyTorchJob with 32
Worker replicas. Each worker runs `torchrun --nproc_per_node=8 --nnodes=32` with
`rdzvBackend: etcd`, requests `nvidia.com/gpu: 8` and `vpc.amazonaws.com/efa: 16`, mounts
`/fsx`, and mounts the `kimi-k2-sft-conf` ConfigMap at `/workspace/conf`. See
[`kubernetes/README.md`](kubernetes/README.md) for the full prerequisites, the required
environment exports, the ConfigMap step, optional KAI gang scheduling, and verification steps.

KAI gang scheduling (a `PodGroup` with `minMember: 32`, so all 32 nodes start together) is
**OPTIONAL** and shipped commented out in the manifest; enable it by uncommenting the relevant
blocks as documented in `kubernetes/README.md`.

## Parallelism and memory budget

Starting point for 256 GPUs, adapted from Megatron-Bridge's DeepSeek-V3 32-node recipe
(`deepseek_v3_pretrain_config_32nodes`). EP must divide the 384 routed experts.

| Dimension | Value | Rationale |
|-----------|-------|-----------|
| Tensor parallel (TP) | 8 | intra-node, over NVLink (8 GPU/node) |
| Expert parallel (EP) | 32 | divides 384 experts (12 experts/rank); spans nodes over EFA |
| Pipeline parallel (PP) | 8 | partitions ~61 transformer layers |
| Data parallel (DP) | fills remainder | `256 / (TP x PP) = 256 / 64 = 4` DP groups |
| Precision | BF16 | `bf16=True` |
| Optimizer | distributed Adam | `use_distributed_optimizer=True` (ZeRO-1 sharding) |
| Activations | full recompute | fit activation memory at this scale |

> The stock DeepSeek-V3 recipe ships `TP=2, PP=8, EP=32`. We raise TP to 8 to keep tensor
> parallel inside one NVLink domain. **Validate the TP/PP/EP product and per-stage layer layout
> against the image** (`set_deepseek_v3_pipeline_model_parallel_layout`) — see
> [Open questions](#open-questions).

### Memory sanity

Model state per GPU, distributed optimizer (BF16 weights + BF16 grads + FP32 Adam moments),
roughly 16 bytes/param:

```text
16 B/param x 1.04e12 params / 256 GPUs ~= 65 GB/GPU model state
```

That leaves ~220 GB of the 288 GB HBM3e per B300 for activations, MoE dispatch buffers, and
fragmentation headroom.

## Known edge cases / validation gates

1. **UCCL `deep_ep` training-backward is unproven.** The shadow module is validated mainly for
   vLLM **inference**. The MoE **combine backward** pass under SFT is the highest risk. Gate:
   confirm gradients flow and loss decreases on the single-node sanity run (step 3) before
   scaling.
2. **`deep_ep` shadow precedence on `sys.path`.** `import deep_ep` must resolve to UCCL's
   wrapper, never to a stray NVIDIA DeepEP install. The image must contain **exactly one**
   top-level `deep_ep`. Verify with `python -c "import deep_ep; print(deep_ep.__file__)"` —
   the path must be under the UCCL wrapper install.
3. **Dispatcher backend override.** The stock DeepSeek-V3 recipe uses
   `moe_token_dispatcher_type="alltoall"` and `moe_flex_dispatcher_backend="hybridep"`. To route
   through the UCCL shadow you must override to `moe_token_dispatcher_type="flex"`,
   `moe_flex_dispatcher_backend="deepep"`, `moe_enable_deepep=True`. If these are not set, the
   all-to-all bypasses `deep_ep` entirely and UCCL is never exercised.
4. **CUDA 13.0.2 / `sm_103` compile.** UCCL-EP must be built with
   `TORCH_CUDA_ARCH_LIST="10.0a+PTX;10.3a+PTX"`. This box is B300-only (`sm_103`); a build that
   only targets `sm_100` (B200) will fail to load or run on B300. Confirm the `.so` loads:
   `python -c "import ep"` (or the UCCL EP module name) inside the image.
5. **EFA count = 16.** Each p6-b300 advertises 16 EFA interfaces (1 of 17 net cards is
   ENA-only). The PyTorchJob requests `vpc.amazonaws.com/efa: 16`. Verify against the device
   plugin's advertised count: `kubectl describe node <p6-b300> | grep vpc.amazonaws.com/efa`.
   A mismatch causes pods to stay `Pending` or starves bandwidth.
6. **Gang scheduling (optional).** Gang scheduling is OPTIONAL and shipped commented out in the
   manifest. If you do NOT enable it, the default scheduler may place a subset of workers and the
   job stalls at rendezvous while capacity-block hours burn — so for capacity blocks, enable the
   KAI `PodGroup` (`minMember: 32`) by uncommenting the manifest blocks (see `kubernetes/README.md`).
   Either way, confirm all 32 workers reach `Running` before training starts.
7. **IB verbs removed.** If `import deep_ep` or UCCL tries to dlopen `libibverbs`, the IB removal
   in the Dockerfile is incomplete or UCCL was built against verbs. Expected fabric is EFA only
   (`FI_PROVIDER=efa`).

## Files

The container environment is shared and lives at the **library level** (one directory up):

| File (in [`../`](../README.md)) | Purpose |
|------|---------|
| `../Dockerfile` | NGC NeMo base + EFA/GDRCopy + UCCL + `deep_ep` shadow (model-agnostic) |
| `../1.build-and-push.sh` | Build the shared env image and push the pinned tag to ECR |
| `../2.sanity-singlenode.sh` | Single-node 8-GPU `deep_ep`/EFA/EP smoke test |
| `../test_megatron_bridge_uccl.py` | CI build smoke test for the shared image |

Model-specific files in **this** directory:

| File | Purpose |
|------|---------|
| `1.convert-checkpoint.sh` | HF Kimi K2 (FP8) -> BF16 -> Megatron-Core checkpoint |
| `conf/kimi_k2_sft.py` | Megatron-Bridge SFT `ConfigContainer` (mounted at `/workspace/conf` via ConfigMap, launched by `torchrun`) |
| `kubernetes/` | etcd `Service`/`Deployment` + PyTorchJob template (+ optional KAI `PodGroup`); create the conf ConfigMap, then `envsubst ... \| kubectl apply` to deploy (see `kubernetes/README.md`) |
| `benchmarks/` | MoE dispatcher A/B harness (NCCL all-to-all vs UCCL DeepEP-over-EFA) |

## References

- [NVIDIA Megatron-Bridge](https://github.com/NVIDIA-NeMo/Megatron-Bridge)
- [Megatron-Bridge docs](https://docs.nvidia.com/nemo/megatron-bridge/)
- [DeepSeek-V3 recipe](https://github.com/NVIDIA-NeMo/Megatron-Bridge/blob/main/src/megatron/bridge/recipes/deepseek/deepseek_v3.py)
- [UCCL project](https://github.com/uccl-project/uccl)
- [Kimi K2 (Moonshot AI)](https://huggingface.co/moonshotai/Kimi-K2-Base)
- Sibling case: [`../../megatron-lm`](../../megatron-lm) (EFA/GDRCopy Dockerfile + PyTorchJob template)
