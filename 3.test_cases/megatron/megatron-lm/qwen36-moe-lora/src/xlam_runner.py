# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
"""Qwen3.6-35B-A3B xLAM function-calling LoRA training driver.

Builds a Megatron-Bridge ConfigContainer from the Qwen3.5-VL MoE LoRA recipe
(which loads its architecture dynamically from HF via AutoBridge, so passing
hf_path="Qwen/Qwen3.6-35B-A3B" correctly targets Qwen 3.6), applies task-specific
overrides (tokenizer, dataset, PEFT, training schedule), and calls finetune().

Invocation (via torchrun inside the training PyTorchJob):
    torchrun --nproc_per_node=$NPROC_PER_NODE --nnodes=$PET_NNODES \\
             --node_rank=$PET_NODE_RANK --master_addr=$MASTER_ADDR \\
             --master_port=$MASTER_PORT xlam_runner.py

Environment variables consumed (all have defaults; override in the PyTorchJob):
    HF_MODEL_ID              HuggingFace model id for the base
    TOKENIZER_PATH           Local path to the HF tokenizer assets
    DATASET_ROOT             Directory containing training.jsonl + validation.jsonl
    PRETRAINED_CHECKPOINT    Bridge distcp dir produced by the conversion pod
    CHECKPOINT_SAVE_DIR      Where to write training checkpoints
    SEQ_LENGTH, MICRO_BS, GLOBAL_BS, TRAIN_ITERS, LR, MIN_LR,
    LORA_DIM, LORA_ALPHA, LORA_TARGET_MODULES
"""
import os

from megatron.bridge.recipes.qwen_vl.qwen35_vl import qwen35_vl_35b_a3b_peft_config
from megatron.bridge.recipes.utils.dataset_utils import apply_dataset_override
from megatron.bridge.training.finetune import finetune
from megatron.bridge.training.gpt_step import forward_step as gpt_forward_step


def _getenv_int(name, default):
    return int(os.environ.get(name, default))


def _getenv_float(name, default):
    return float(os.environ.get(name, default))


def _getenv_list(name, default):
    raw = os.environ.get(name)
    if not raw:
        return list(default)
    return [s.strip() for s in raw.split(",") if s.strip()]


def main():
    hf_model_id = os.environ.get("HF_MODEL_ID", "Qwen/Qwen3.6-35B-A3B")
    tokenizer_path = os.environ.get("TOKENIZER_PATH", "/fsx/hf_cache/models--Qwen--Qwen3.6-35B-A3B")
    dataset_root = os.environ.get("DATASET_ROOT", "/fsx/datasets")
    pretrained_ckpt = os.environ.get("PRETRAINED_CHECKPOINT", "/fsx/qwen36-bridge")
    save_dir = os.environ.get("CHECKPOINT_SAVE_DIR", "/fsx/qwen36-xlam-runs/checkpoints")

    seq_length = _getenv_int("SEQ_LENGTH", 2048)
    micro_bs = _getenv_int("MICRO_BS", 3)
    global_bs = _getenv_int("GLOBAL_BS", 48)
    train_iters = _getenv_int("TRAIN_ITERS", 4200)
    lr = _getenv_float("LR", 1.5e-4)
    min_lr = _getenv_float("MIN_LR", 1.5e-5)
    warmup_iters = _getenv_int("WARMUP_ITERS", 100)
    eval_interval = _getenv_int("EVAL_INTERVAL", 500)
    save_interval = _getenv_int("SAVE_INTERVAL", 500)
    log_interval = _getenv_int("LOG_INTERVAL", 10)

    lora_dim = _getenv_int("LORA_DIM", 64)
    lora_alpha = _getenv_int("LORA_ALPHA", 128)
    lora_target_modules = _getenv_list(
        "LORA_TARGET_MODULES", ["linear_qkv", "linear_proj"]
    )

    # 1. Load the recipe. AutoBridge dynamically loads the model config via
    #    hf_path, so passing Qwen3.6 here correctly configures num_moe_experts=256,
    #    moe_router_topk=8, etc., even though the recipe function name says "qwen35".
    cfg = qwen35_vl_35b_a3b_peft_config(
        peft_scheme="lora",
        hf_path=hf_model_id,
    )

    # 2. Text-only SFT dataset (xLAM JSONL).
    cfg = apply_dataset_override(cfg, dataset_type="llm-finetune-preloaded",
                                 seq_length=seq_length)
    cfg.dataset.dataset_root = dataset_root
    cfg.dataset.seq_length = seq_length

    # 3. Model-level overrides: freeze the VL encoder (we do text-only SFT).
    cfg.model.seq_length = seq_length
    cfg.model.freeze_vision_model = True
    cfg.model.freeze_vision_projection = True

    # 4. Force the HF text tokenizer. The VL recipe defaults to NullTokenizer,
    #    which crashes FinetuningDatasetBuilder at `tokenizer.space_sensitive`.
    cfg.tokenizer.tokenizer_type = "HuggingFaceTokenizer"
    cfg.tokenizer.tokenizer_model = tokenizer_path

    # 5. PEFT overrides (can't be set via Hydra CLI — peft is attached to the
    #    ConfigContainer dynamically, not a schema field).
    cfg.peft.dim = lora_dim
    cfg.peft.alpha = lora_alpha
    cfg.peft.target_modules = lora_target_modules
    # NOTE: excluding linear_fc1/linear_fc2 is critical for MoE models. Those
    # target each expert's MLP — applying LoRA there would bloat the adapter
    # ~256x (one per expert) and break EP sharding.

    # 6. Checkpoints.
    cfg.checkpoint.pretrained_checkpoint = pretrained_ckpt
    cfg.checkpoint.save = save_dir

    # 7. Training schedule.
    cfg.train.train_iters = train_iters
    cfg.train.global_batch_size = global_bs
    cfg.train.micro_batch_size = micro_bs
    cfg.train.eval_iters = 20
    cfg.train.eval_interval = eval_interval
    cfg.train.log_interval = log_interval
    cfg.train.save_interval = save_interval

    cfg.optimizer.lr = lr
    cfg.optimizer.min_lr = min_lr

    cfg.scheduler.lr_warmup_iters = warmup_iters
    cfg.scheduler.lr_decay_iters = train_iters
    cfg.scheduler.lr_decay_style = "cosine"

    # 8. Logger. Put TensorBoard on the shared FSx mount so monitoring pods can
    #    read it without the training pod being modified.
    cfg.logger.log_interval = log_interval
    cfg.logger.log_throughput = True
    cfg.logger.log_params_norm = True
    cfg.logger.log_l2_norm_grad_to_tensorboard = True
    cfg.logger.tensorboard_dir = os.path.join(os.path.dirname(save_dir), "tb_logs")

    finetune(cfg, gpt_forward_step)


if __name__ == "__main__":
    main()
