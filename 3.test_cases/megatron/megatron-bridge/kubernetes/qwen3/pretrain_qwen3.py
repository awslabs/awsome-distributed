# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""
Qwen 3 pretraining with Megatron-Bridge on AWS.

This script uses the official Megatron-Bridge AutoBridge API
(https://pypi.org/project/megatron-bridge/) to bridge Hugging Face Qwen 3
models into Megatron-Core format for efficient distributed training with
tensor parallelism and pipeline parallelism.

See: https://github.com/NVIDIA-NeMo/Megatron-Bridge

Supported model sizes: 0.6B, 1.7B, 4B, 8B, 14B, 32B.

Usage (launched by torchrun via PyTorchJob):
    torchrun --nproc_per_node=8 --nnodes=2 pretrain_qwen3.py \
        --model-size 8b \
        --hf-model-path /fsx/qwen3/8b \
        --train-iters 10
"""

import argparse
import os
import time

import torch
import torch.distributed as dist

from megatron.bridge import AutoBridge


# Qwen 3 model configurations with recommended parallelism for H100 80GB
MODEL_CONFIGS = {
    "0.6b": {"hf_model": "Qwen/Qwen3-0.6B", "tp": 1, "pp": 1},
    "1.7b": {"hf_model": "Qwen/Qwen3-1.7B", "tp": 1, "pp": 1},
    "4b": {"hf_model": "Qwen/Qwen3-4B", "tp": 2, "pp": 1},
    "8b": {"hf_model": "Qwen/Qwen3-8B", "tp": 4, "pp": 1},
    "14b": {"hf_model": "Qwen/Qwen3-14B", "tp": 8, "pp": 1},
    "32b": {"hf_model": "Qwen/Qwen3-32B", "tp": 8, "pp": 2},
}


def parse_args():
    parser = argparse.ArgumentParser(
        description="Qwen 3 pretraining with Megatron-Bridge + Megatron-Core"
    )
    parser.add_argument(
        "--model-size",
        type=str,
        default="8b",
        choices=list(MODEL_CONFIGS.keys()),
        help="Qwen 3 model size (default: 8b)",
    )
    parser.add_argument(
        "--hf-model-path",
        type=str,
        default=None,
        help="Path to local HF model on shared storage (e.g., /fsx/qwen3/8b).",
    )
    parser.add_argument(
        "--train-iters", type=int, default=10, help="Training iterations"
    )
    parser.add_argument("--seq-length", type=int, default=4096, help="Sequence length")
    parser.add_argument(
        "--global-batch-size", type=int, default=16, help="Global batch size"
    )
    parser.add_argument(
        "--micro-batch-size", type=int, default=1, help="Micro batch size per GPU"
    )
    parser.add_argument("--lr", type=float, default=6.0e-5, help="Learning rate")
    parser.add_argument(
        "--tp", type=int, default=None, help="Tensor parallel size override"
    )
    parser.add_argument(
        "--pp", type=int, default=None, help="Pipeline parallel size override"
    )
    return parser.parse_args()


def main():
    args = parse_args()
    model_cfg = MODEL_CONFIGS[args.model_size]

    hf_model_path = args.hf_model_path or model_cfg["hf_model"]
    tp = args.tp or model_cfg["tp"]
    pp = args.pp or model_cfg["pp"]

    # torchrun sets LOCAL_RANK, RANK, WORLD_SIZE, MASTER_ADDR, MASTER_PORT
    local_rank = int(os.environ.get("LOCAL_RANK", 0))
    rank = int(os.environ.get("RANK", 0))
    world_size = int(os.environ.get("WORLD_SIZE", 1))

    # Set the GPU for this process
    torch.cuda.set_device(local_rank)

    # Initialize the process group (torchrun provides the env vars)
    dist.init_process_group(backend="nccl")

    if rank == 0:
        print(f"[Megatron-Bridge] Qwen3-{args.model_size.upper()} pretraining")
        print(f"[Megatron-Bridge] World size: {world_size}, TP={tp}, PP={pp}")
        print(f"[Megatron-Bridge] Model path: {hf_model_path}")
        print(
            f"[Megatron-Bridge] Seq={args.seq_length}, GBS={args.global_batch_size}, Iters={args.train_iters}"
        )

    # Initialize Megatron-Core parallel state and build model via AutoBridge
    if rank == 0:
        print("[Megatron-Bridge] Creating bridge and loading model...")

    bridge = AutoBridge.from_hf_pretrained(hf_model_path, trust_remote_code=True)

    # Configure parallelism through the Megatron provider
    provider = bridge.to_megatron_provider()
    provider.tensor_model_parallel_size = tp
    provider.pipeline_model_parallel_size = pp
    provider.finalize()

    # Load with weights if model path is a local dir with weights
    has_weights = os.path.isdir(hf_model_path) and any(
        f.endswith(".safetensors") for f in os.listdir(hf_model_path)
    )

    if has_weights:
        if rank == 0:
            print(f"[Megatron-Bridge] Loading weights from {hf_model_path}")
        model = provider.provide_distributed_model(wrap_with_ddp=False)
        bridge.load_hf_weights(model, hf_model_path)
    else:
        if rank == 0:
            print("[Megatron-Bridge] Using random weights (mock/benchmark mode)")
        model = provider.provide_distributed_model(wrap_with_ddp=False)

    # Megatron-Core parameters use main_grad for gradient accumulation in their
    # custom autograd functions (forward ctx saves weight.main_grad). Allocate
    # main_grad buffers on ALL parameters before the first forward pass.
    for m in model:
        for p in m.parameters():
            if not hasattr(p, "main_grad") or p.main_grad is None:
                p.main_grad = torch.zeros_like(p.data)

    if rank == 0:
        total_params = sum(p.numel() for m in model for p in m.parameters())
        trainable_params = sum(
            p.numel() for m in model for p in m.parameters() if p.requires_grad
        )
        print(
            f"[Megatron-Bridge] Model built: {total_params / 1e9:.2f}B params, {trainable_params / 1e9:.2f}B trainable"
        )

    # Optimizer
    params = [p for m in model for p in m.parameters() if p.requires_grad]

    optimizer = torch.optim.AdamW(
        params, lr=args.lr, weight_decay=0.1, betas=(0.9, 0.95)
    )

    # Simple training loop with mock data
    vocab_size = 151936  # Qwen3 vocab
    seq_len = args.seq_length

    if rank == 0:
        print(
            f"\n[Megatron-Bridge] Starting training for {args.train_iters} iterations..."
        )

    for step in range(1, args.train_iters + 1):
        t0 = time.time()

        # Generate mock batch on the correct device
        input_ids = torch.randint(
            0, vocab_size, (args.micro_batch_size, seq_len), device=f"cuda:{local_rank}"
        )
        position_ids = (
            torch.arange(seq_len, device=f"cuda:{local_rank}")
            .unsqueeze(0)
            .expand(args.micro_batch_size, -1)
        )
        attention_mask = torch.ones_like(input_ids)

        # Forward pass (model is a list of pipeline-parallel chunks)
        output = model[0](input_ids, position_ids, attention_mask)
        loss = output.float().mean()

        # Backward pass (gradients accumulate in param.main_grad)
        loss.backward()

        # Copy main_grad -> grad for the standard PyTorch optimizer
        for p in params:
            if p.main_grad is not None:
                if p.grad is None:
                    p.grad = p.main_grad.to(p.data.dtype)
                else:
                    p.grad.copy_(p.main_grad)

        optimizer.step()

        # Zero both grad and main_grad
        optimizer.zero_grad()
        for m in model:
            for p in m.parameters():
                if hasattr(p, "main_grad") and p.main_grad is not None:
                    p.main_grad.zero_()

        dt = time.time() - t0

        if rank == 0:
            tps = args.micro_batch_size * seq_len * world_size / dt
            print(
                f"  step {step:>3}/{args.train_iters} | loss: {loss.item():.4f} | time: {dt:.2f}s | tokens/s: {tps:,.0f}"
            )

    if rank == 0:
        print("\n[Megatron-Bridge] Training complete!")

    dist.destroy_process_group()


if __name__ == "__main__":
    main()
