#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# 1.convert-checkpoint.sh
#
# Download Kimi K2 HuggingFace weights, dequantize block-FP8 -> BF16 (inline
# during import), and convert to a Megatron-Core distributed checkpoint on FSx
# via Megatron-Bridge AutoBridge.import_ckpt().
#
# Run this script INSIDE the training container (from 1.build-and-push.sh) on a
# node that has FSx Lustre mounted at /fsx.  It does NOT need torchrun — the
# AutoBridge import_ckpt() path is single-process.  If single-process import
# OOMs on 4 TB RAM, see the TODO below for the multi-GPU fallback.
#
# FSx budget (approximate):
#   - HF weights (block-FP8, moonshotai/Kimi-K2-Base): ~1 TB
#   - Megatron-Core BF16 checkpoint (written by import_ckpt):  ~2 TB
#   - Working / cache headroom:                               ~1-2 TB
#   Total: plan for at least 4-5 TB free on your FSx volume.
#
# Usage:
#   # Minimal (uses defaults below):
#   bash 1.convert-checkpoint.sh
#
#   # Override paths / model:
#   HF_MODEL_ID=moonshotai/Kimi-K2-Base \
#   FSX_ROOT=/fsx/kimi-k2 \
#   HF_TOKEN=hf_xxx \
#   bash 1.convert-checkpoint.sh

set -euo pipefail

###############################################################################
# User-configurable variables (override via environment before invoking)
###############################################################################

# HuggingFace model repo and revision (commit SHA — do not use 'main').
# Full-parameter SFT starts from the *Base* repo (matches the config's
# KIMI_K2_HF_ID). Swap for Kimi-K2-Instruct only for instruction-tuned starts.
HF_MODEL_ID="${HF_MODEL_ID:-moonshotai/Kimi-K2-Base}"
# Revision MUST be pinned to a commit SHA (enforced in Step 0 below).
# TODO: resolve and pin the commit SHA before use, e.g. from
#   https://huggingface.co/moonshotai/Kimi-K2-Base/commits/main
# Find it via: huggingface-cli revision "${HF_MODEL_ID}"
HF_REVISION="${HF_REVISION:-}"

# FSx Lustre mount point
# Canonical FSx root for this run (matches conf/kimi_k2_sft.py and the manifest).
FSX_ROOT="${FSX_ROOT:-/fsx/kimi-k2}"

# Where to cache the raw HF download (block-FP8, ~1 TB)
FSX_HF_DIR="${FSX_HF_DIR:-${FSX_ROOT}/hf}"

# Where Megatron-Bridge writes the MCore distributed checkpoint (BF16, ~2 TB)
FSX_MCORE_DIR="${FSX_MCORE_DIR:-${FSX_ROOT}/mcore}"

# HuggingFace access token (required if the repo is gated).
# Set to an empty string if the repo is public.
HF_TOKEN="${HF_TOKEN:-}"

###############################################################################
# Step 0: Validate environment
###############################################################################

echo "=========================================================="
echo "Kimi K2 checkpoint conversion"
echo "  HF model:     ${HF_MODEL_ID} @ ${HF_REVISION}"
echo "  HF cache dir: ${FSX_HF_DIR}"
echo "  MCore dir:    ${FSX_MCORE_DIR}"
echo "=========================================================="

# Confirm FSx is reachable. FSX_ROOT is a per-run subdir (created below if absent),
# so check its parent mount point rather than FSX_ROOT itself.
FSX_MOUNT="$(dirname "${FSX_ROOT}")"
if [[ ! -d "${FSX_MOUNT}" ]]; then
    echo "ERROR: FSx mount '${FSX_MOUNT}' does not exist. Is the volume mounted?" >&2
    exit 1
fi
mkdir -p "${FSX_ROOT}"

# Enforce a pinned revision: an empty or 'main' revision is a convention
# violation (non-reproducible). Require a commit SHA.
# TODO: pin to a commit SHA from
#   https://huggingface.co/moonshotai/Kimi-K2-Base/commits/main
if [[ -z "${HF_REVISION}" || "${HF_REVISION}" == "main" ]]; then
    echo "ERROR: HF_REVISION is unset or 'main'. Pin it to a commit SHA for a" >&2
    echo "       reproducible conversion, e.g.:" >&2
    echo "         HF_REVISION=<commit-sha> bash 1.convert-checkpoint.sh" >&2
    echo "       Find the SHA at https://huggingface.co/${HF_MODEL_ID}/commits/main" >&2
    exit 1
fi

# Confirm Megatron-Bridge is installed (installed into the NGC base image)
python - <<'PYCHECK'
try:
    from megatron.bridge import AutoBridge  # noqa: F401
except ImportError as e:
    raise SystemExit(f"megatron.bridge not importable — is the training container in use? {e}")
PYCHECK

###############################################################################
# Step 1: Download HuggingFace weights (block-FP8, ~1 TB)
###############################################################################

mkdir -p "${FSX_HF_DIR}"

echo ""
echo "[1/2] Downloading HF weights -> ${FSX_HF_DIR}"

# HF_HUB_ENABLE_HF_TRANSFER speeds downloads (uses the hf_transfer C backend
# if installed; silently falls back to Python if not).
export HF_HUB_ENABLE_HF_TRANSFER=1

TOKEN_ARGS=()
if [[ -n "${HF_TOKEN:-}" ]]; then
    TOKEN_ARGS=(--token "${HF_TOKEN}")
fi

huggingface-cli download \
    "${HF_MODEL_ID}" \
    --revision "${HF_REVISION}" \
    --local-dir "${FSX_HF_DIR}" \
    "${TOKEN_ARGS[@]+"${TOKEN_ARGS[@]}"}"

echo "Download complete."

###############################################################################
# Step 2: HF -> MCore checkpoint conversion via Megatron-Bridge
#
# AutoBridge.import_ckpt() is the single-process convenience wrapper shown in
# examples/conversion/convert_checkpoints.py for Megatron-Bridge v0.4.0
# (the version shipped in nvcr.io/nvidia/nemo:25.11.01).
#
# It calls AutoBridge.from_hf_pretrained(hf_model_id, torch_dtype=bfloat16)
# followed by provider.finalize() + save_megatron_model() in one shot.
# Block-FP8 weights are dequantized inline to BF16 during this step.
#
# TODO(validate against image): the import_ckpt signature below and whether a
# Kimi-K2 *text* bridge mapping exists are UNVERIFIED against the v0.4.0 image.
# Bridge main ships Moonlight / Kimi-K2.5-VL; Kimi K2 is DeepSeek-V3-family so the
# DeepSeek bridge may cover it via trust_remote_code, but confirm against the image
# (a dedicated kimi_bridge.py may or may not be present). Mirrors the config's stance
# that Kimi-K2 text AutoBridge support is unverified.
#   AutoBridge.import_ckpt(
#       hf_model_id=<str>,
#       megatron_path=<str>,
#       torch_dtype=<torch.dtype>,   # torch.bfloat16 recommended for SFT
#       device_map=<str|None>,       # "auto" spreads across visible GPUs
#       trust_remote_code=<bool>,    # True required for KimiK2ForCausalLM config
#   )
# Ref: https://github.com/NVIDIA-NeMo/Megatron-Bridge
#
# NOTE on parallelism: import_ckpt does NOT accept tp/pp/ep arguments — the
# MCore checkpoint it writes is parallelism-agnostic (TP=1, PP=1, EP=1).
# Megatron-Bridge reshards on the fly at training time via the training
# config's tensor_model_parallel_size / expert_model_parallel_size fields.
#
# TODO(validate against image): if this single-process import OOMs (4 TB RAM
# is tight for 1.04T params at BF16 + intermediate buffers), fall back to the
# multi-GPU distributed conversion using torchrun:
#
#   torchrun --nproc_per_node=8 \
#     /path/to/hf_megatron_roundtrip_multi_gpu.py \
#     --hf-model-id "${FSX_HF_DIR}" \
#     --megatron-save-path "${FSX_MCORE_DIR}" \
#     --tp 8 --ep 8 --pp 1 \
#     --trust-remote-code
#
# The multi-GPU script is at:
#   https://github.com/NVIDIA-NeMo/Megatron-Bridge/blob/v0.4.0/examples/conversion/hf_megatron_roundtrip_multi_gpu.py
###############################################################################

mkdir -p "${FSX_MCORE_DIR}"

echo ""
echo "[2/2] Converting HF -> MCore (AutoBridge.import_ckpt) -> ${FSX_MCORE_DIR}"
echo "      This step dequantizes block-FP8 weights to BF16 inline."
echo "      Expected runtime: 30-90 min on a single node with fast FSx throughput."

python - <<PYEOF
import torch
from megatron.bridge import AutoBridge

# trust_remote_code=True is required: KimiK2ForCausalLM is defined in the
# Moonshot AI repo config and not registered in stock transformers.
AutoBridge.import_ckpt(
    hf_model_id="${FSX_HF_DIR}",
    megatron_path="${FSX_MCORE_DIR}",
    torch_dtype=torch.bfloat16,
    trust_remote_code=True,
)
print("import_ckpt complete.")
PYEOF

echo ""
echo "=========================================================="
echo "Checkpoint conversion finished."
echo "  MCore checkpoint: ${FSX_MCORE_DIR}"
echo ""
echo "Next step: run the single-node sanity gate (2.sanity-singlenode.sh), then"
echo "deploy the 32-node PyTorchJob (see kubernetes/README.md). The training job"
echo "reads this checkpoint via KIMI_K2_MCORE_CKPT=${FSX_MCORE_DIR}."
echo "=========================================================="
