<!-- Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved. -->
<!-- SPDX-License-Identifier: MIT-0 -->

# OpenVLA-OFT Fine-tuning

Fine-tune the [OpenVLA](https://huggingface.co/openvla/openvla-7b) vision-language-action (VLA) model using the [OFT (Optimized Fine-Tuning)](https://github.com/moojink/openvla-oft) recipe from Moo Jin Kim et al.

OFT improves vanilla OpenVLA fine-tuning with parallel action decoding, action chunking, and a continuous-action head (L1 regression or diffusion). This test case packages the upstream `vla-scripts/finetune.py` into a container image and a distributed training manifest so you can run it on AWS-backed Kubernetes (EKS or SageMaker HyperPod-on-EKS).

## Layout

```
openvla-oft/
├── Dockerfile                   # Container image with openvla-oft + training script
├── README.md                    # This file
├── src/
│   └── finetune.py              # Fine-tuning script (adapted from openvla-oft: +3 distributed fixes)
└── kubernetes/
    └── libero/                  # LIBERO recipe (PyTorchJob + Download Job + helpers)
        ├── README.md            # End-to-end LIBERO walkthrough
        ├── env_vars.example     # Tracked template for env_vars (gitignored)
        ├── libero-download.yaml # One-shot dataset staging Job
        ├── libero-finetune.yaml # PyTorchJob manifest (uses envsubst)
        ├── pvc-fsx-lustre-dynamic.yaml # Optional: dynamic FSx provisioning
        ├── pv-fsx-lustre-static.yaml   # Optional: static FSx binding
        └── verify-tfds-layout.sh       # Sanity-check the staged dataset
```

A `slurm/` sibling folder is intentionally left out for now and will be added in a follow-up.

## Prerequisites

- A Kubernetes cluster with GPU nodes (EKS, or SageMaker HyperPod-on-EKS). See [1.architectures/4.amazon-eks](../../../1.architectures/4.amazon-eks) for cluster setup.
- The [Kubeflow training operator](https://github.com/kubeflow/training-operator) installed for the `PyTorchJob` CRD.
- Shared storage (FSx for Lustre, EFS, or similar) mounted into the pods via a `PersistentVolumeClaim`. The manifest expects it at `/data` and uses it for:
  - `/data/datasets/rlds` — your RLDS-format demonstration data
  - `/data/runs` — checkpoint and log output
  - `/data/hf-cache` — Hugging Face model cache
- A Hugging Face token with access to `openvla/openvla-7b` (the repo is public but gated by an access request).
- Optional: a Weights & Biases account for training metrics.

## Data

OpenVLA-OFT expects datasets in [RLDS](https://github.com/google-research/rlds) format. See the [openvla-oft README](https://github.com/moojink/openvla-oft#fine-tuning-openvla-via-oft) for how to prepare datasets (e.g. ALOHA, LIBERO, BridgeData V2). Place the resulting `datasets/rlds/<dataset_name>` tree under your PVC at `/data/datasets/rlds/`.

## Next step

Head to [kubernetes/libero/README.md](kubernetes/libero/README.md) for the end-to-end build-image → push-to-ECR → submit-PyTorchJob walkthrough. The recipe pins the exact hyperparameters from upstream [LIBERO.md](https://github.com/moojink/openvla-oft/blob/main/LIBERO.md) and adds a one-shot dataset download Job that stages `openvla/modified_libero_rlds` onto the shared PVC before training.

A generic (non-LIBERO) Kubernetes recipe is intentionally left out for now and will be added in a follow-up once it has been tested end-to-end on its own. Until then, treat the LIBERO walkthrough as the reference for the Dockerfile build, ECR push, and PyTorchJob submission steps.

## References

- OpenVLA-OFT paper: [Fine-Tuning Vision-Language-Action Models: Optimizing Speed and Success](https://arxiv.org/abs/2502.19645)
- Upstream code: [moojink/openvla-oft](https://github.com/moojink/openvla-oft)
- Base model: [openvla/openvla-7b](https://huggingface.co/openvla/openvla-7b)
