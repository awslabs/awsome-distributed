<!-- Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved. -->
<!-- SPDX-License-Identifier: MIT-0 -->

# Megatron-Bridge + UCCL-EP over EFA

This directory is the **library-level**, **model-agnostic** home for
[NVIDIA Megatron-Bridge](https://github.com/NVIDIA-NeMo/Megatron-Bridge) test cases
that run Mixture-of-Experts (MoE) training on Amazon EKS with
[UCCL-EP](https://github.com/uccl-project/uccl) carrying the expert-parallel
all-to-all over **AWS EFA**.

The crux is replacing NVIDIA [DeepEP](https://github.com/deepseek-ai/DeepEP) (which is
built on NVSHMEM + InfiniBand verbs and does **not** run on EFA) with UCCL's EFA-native
drop-in — **without patching Megatron-Core**. UCCL ships a top-level `deep_ep` shadow
module; because it installs into `site-packages`, `import deep_ep` resolves to UCCL's
EFA RDMA implementation. Megatron-Core's MoE `flex`/`deepep` dispatcher then sends its
all-to-all bytes over EFA via UCCL + GDRCopy instead of over IB verbs via NVSHMEM.

## Layout

The container environment (Dockerfile + its build/validation scripts) lives here at the
library level and is **shared by every model** under it. Per-model recipes (checkpoint
conversion, the SFT `conf`, deployment manifests, benchmarks) live in a model subdirectory.

```text
megatron-bridge/                  # <library> — model-agnostic environment
├── Dockerfile                    # NGC NeMo base + EFA/GDRCopy + UCCL + deep_ep shadow
├── 1.build-and-push.sh           # build the shared env image and push the pinned tag to ECR
├── 2.sanity-singlenode.sh        # single-node 8-GPU deep_ep/EFA/EP smoke gate (run in the image)
├── test_megatron_bridge_uccl.py  # CI build smoke test for the shared image
└── kimi-k2/                      # <model> — Kimi K2 full-parameter SFT recipe
    ├── README.md
    ├── 1.convert-checkpoint.sh
    ├── conf/                     # SFT ConfigContainer (mounted into the image at runtime)
    ├── kubernetes/
    └── benchmarks/
```

The image is **model-agnostic**: SFT configs are **not** baked in. Each model mounts its
own `conf/` at `/workspace/conf` at runtime (e.g. via a ConfigMap — see the model's
`kubernetes/README.md`), so one image serves every model under this library.

## Shared environment workflow

These two steps build and validate the shared image and apply to **all** models. Run them
from this directory, then continue in the model subdirectory.

### 1. Build the environment image and push to ECR

`1.build-and-push.sh` builds `Dockerfile`, creates the ECR repository if needed
(`megatron-bridge-uccl`), logs in, and pushes the pinned tag `nemo-25.11.01-uccl-0dc87eb`
(no `latest`). The Dockerfile starts from `nvcr.io/nvidia/nemo:25.11.01` (CUDA 13.0.2,
PyTorch 2.10), which already ships **Megatron-Bridge v0.4.0**, Megatron-Core (with the
`flex`/`deepep` dispatcher), and TransformerEngine — these are **not** reinstalled. It then
strips the IB fabric, lays down GDRCopy `v2.5.2` + the EFA installer `1.48.0`, and builds
UCCL (pinned to commit `0dc87eb`) / UCCL-EP for `sm_103` (B300) plus the `deep_ep` shadow.

```bash
bash 1.build-and-push.sh
# Image: 159553542841.dkr.ecr.us-west-2.amazonaws.com/megatron-bridge-uccl:nemo-25.11.01-uccl-0dc87eb
```

### 2. Single-node sanity gate

**Do not skip this.** It is far cheaper to fail on 1 node than to burn 32 capacity-block
nodes. `2.sanity-singlenode.sh` runs a single-node, 8-GPU smoke test **inside the image**
that confirms the UCCL `deep_ep` wrapper is active, EFA is present, and an EP forward +
backward micro-step runs through `MoEFlexTokenDispatcher` with `backend="deepep"`.

```bash
# inside the container on one p6-b300.48xlarge node:
bash 2.sanity-singlenode.sh
```

## Models

| Model | Directory | Recipe |
|-------|-----------|--------|
| [Kimi K2](https://huggingface.co/moonshotai/Kimi-K2-Base) (1.04T MoE) | [`kimi-k2/`](kimi-k2/) | Full-parameter SFT on 32× p6-b300 (256× B300) |

To add a model: create `megatron-bridge/<model>/` with its `conf/`, deployment manifests,
and a model README. Reuse the shared image from step 1 (mount the model's `conf` at runtime)
— do **not** add a second Dockerfile.

## References

- [NVIDIA Megatron-Bridge](https://github.com/NVIDIA-NeMo/Megatron-Bridge)
- [Megatron-Bridge docs](https://docs.nvidia.com/nemo/megatron-bridge/)
- [UCCL project](https://github.com/uccl-project/uccl)
- Sibling case: [`../megatron-lm`](../megatron-lm) (EFA/GDRCopy Dockerfile + PyTorchJob template)
