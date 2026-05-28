<!-- Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved. -->
<!-- SPDX-License-Identifier: MIT-0 -->

# Qwen 3 Pretraining with Megatron-Bridge on Kubernetes

This directory contains the training script and Kubernetes manifests for pretraining
Qwen 3 models with Megatron-Bridge.

See the [main README](../../README.md) for the complete walkthrough including
container build, ECR push, model download, training launch, and validated results.

## Contents

| File | Description |
|------|-------------|
| `pretrain_qwen3.py` | Training script using the Megatron-Bridge AutoBridge API |
| `manifests/pytorchjob.yaml-template` | PyTorchJob manifest template for distributed training |
| `manifests/download-model-job.yaml-template` | Job manifest template for downloading HF model weights to FSx |
