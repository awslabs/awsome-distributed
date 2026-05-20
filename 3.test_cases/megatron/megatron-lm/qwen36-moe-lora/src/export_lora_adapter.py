# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
"""Export a Megatron-Bridge distributed LoRA checkpoint to HuggingFace PEFT format.

Reads the distcp shard directory written by the training job and emits:
    <output>/adapter_config.json
    <output>/adapter_model.safetensors

The output is directly loadable by `peft.PeftModel.from_pretrained(...)` and by
vLLM via `--lora-modules <name>=<output-dir>`.

Must run under torchrun with matching parallelism (TP=2, PP=1, EP=4 for this test
case). The conversion is done by:
  1. Re-instantiating the base model architecture via AutoBridge
  2. Loading dense base weights (needed for shape reference)
  3. Attaching LoRA wrappers that match training config
  4. Loading the adapter shards via dist_checkpointing with a filtered state dict
  5. Calling bridge.save_hf_adapter(...) which writes the HF PEFT files

Invocation:
    torchrun --nproc_per_node=8 export_lora_adapter.py \\
        --lora-checkpoint /fsx/qwen36-xlam-runs/checkpoints/iter_0004200 \\
        --hf-model         Qwen/Qwen3.6-35B-A3B \\
        --base-checkpoint  /fsx/qwen36-bridge \\
        --output           /fsx/qwen36-xlam-runs/adapter_hf \\
        --tp 2 --pp 1 --ep 4
"""
import argparse
import logging
from pathlib import Path

import torch
import torch.distributed as dist
from megatron.core import dist_checkpointing
from megatron.core.dist_checkpointing.validation import StrictHandling

from megatron.bridge.models.conversion.auto_bridge import AutoBridge
from megatron.bridge.peft.lora import LoRA, VLMLoRA
from megatron.bridge.training.checkpointing import (
    _generate_model_state_dict,
    apply_peft_adapter_filter_to_state_dict,
)
from megatron.bridge.training.utils.checkpoint_utils import read_run_config
from megatron.bridge.utils.common_utils import print_rank_0


logger = logging.getLogger(__name__)


def parse_args():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--lora-checkpoint", required=True,
                   help="Path to iter_NNNNNNN directory containing the trained LoRA adapter")
    p.add_argument("--hf-model", required=True,
                   help="HF model id for the base (e.g. Qwen/Qwen3.6-35B-A3B)")
    p.add_argument("--output", required=True,
                   help="Where to write adapter_config.json + adapter_model.safetensors")
    p.add_argument("--base-checkpoint", default=None,
                   help="Bridge distcp directory for the base dense model. If omitted, "
                        "read from run_config.yaml inside the LoRA checkpoint.")
    p.add_argument("--tp", type=int, default=2)
    p.add_argument("--pp", type=int, default=1)
    p.add_argument("--ep", type=int, default=4)
    return p.parse_args()


def main():
    args = parse_args()

    # 1. Build the HF bridge config (no weights yet).
    print_rank_0(f"[export] Building AutoBridge from {args.hf_model}")
    bridge = AutoBridge.from_hf_pretrained(args.hf_model, trust_remote_code=True)

    provider = bridge.to_megatron_provider(load_weights=False)
    provider.tensor_model_parallel_size = args.tp
    provider.pipeline_model_parallel_size = args.pp
    provider.expert_model_parallel_size = args.ep
    provider.expert_tensor_parallel_size = 1
    provider.pipeline_dtype = torch.bfloat16

    # initialize_model_parallel() also seeds Megatron's TP-aware RNG, which is
    # required before any transformer layer can be materialized (otherwise
    # TransformerEngine's `random.fork('model-parallel-rng')` raises).
    provider.initialize_model_parallel(seed=0)

    mp_overrides = {
        "tensor_model_parallel_size": args.tp,
        "pipeline_model_parallel_size": args.pp,
        "expert_model_parallel_size": args.ep,
    }

    # 2. Locate the base dense checkpoint (needed by load_megatron_model).
    lora_dir = Path(args.lora_checkpoint)
    base_dir = args.base_checkpoint
    if base_dir is None:
        cfg_file = lora_dir / "run_config.yaml"
        if not cfg_file.exists():
            cfg_file = lora_dir.parent.parent / "run_config.yaml"
        if cfg_file.exists():
            run_cfg = read_run_config(str(cfg_file))
            base_dir = run_cfg.get("checkpoint", {}).get("pretrained_checkpoint")
    if base_dir is None:
        raise SystemExit("Could not determine base checkpoint path; pass --base-checkpoint")
    print_rank_0(f"[export] Base dense checkpoint: {base_dir}")

    # 3. Load the base dense weights.
    print_rank_0("[export] Loading base dense model")
    model = bridge.load_megatron_model(str(base_dir), mp_overrides=mp_overrides)

    # 4. Read peft hyperparameters from the LoRA checkpoint's run_config.yaml.
    cfg_file = lora_dir / "run_config.yaml"
    if not cfg_file.exists():
        cfg_file = lora_dir.parent.parent / "run_config.yaml"

    peft_cfg = {}
    peft_class = LoRA
    if cfg_file.exists():
        run_cfg_dict = read_run_config(str(cfg_file))
        peft_cfg = run_cfg_dict.get("peft", {}) or {}
        target = peft_cfg.get("_target_", "")
        if "VLMLoRA" in target:
            peft_class = VLMLoRA
        allowed = {"target_modules", "dim", "alpha", "dropout",
                   "dropout_position",
                   "freeze_language_model", "freeze_vision_model",
                   "freeze_vision_projection"}
        peft_cfg = {k: v for k, v in peft_cfg.items() if k in allowed}
    print_rank_0(f"[export] PEFT class {peft_class.__name__} with cfg: {peft_cfg}")
    lora_peft = peft_class(**peft_cfg)

    # 5. Attach LoRA wrappers (no weights yet — those come next).
    model = lora_peft(model, training=False)

    # 6. Load adapter weights. Use a filtered state dict so dist_checkpointing
    #    only tries to match adapter tensors, not the base weights + optimizer
    #    state + scheduler + content_metadata that live alongside them in the
    #    training checkpoint.
    print_rank_0(f"[export] Loading adapter weights from {lora_dir}")
    sharded_state_dict = _generate_model_state_dict(model, {})
    sharded_state_dict = apply_peft_adapter_filter_to_state_dict(
        sharded_state_dict, lora_peft
    )

    loaded_sd = dist_checkpointing.load(
        sharded_state_dict, str(lora_dir),
        strict=StrictHandling.LOG_UNEXPECTED,
    )
    model_section_key = (
        "model" if "model" in loaded_sd
        else next(k for k in loaded_sd if k.startswith("model"))
    )
    adapter_sd = loaded_sd[model_section_key]
    model[0].load_state_dict(adapter_sd, strict=False)

    # 7. Write HF PEFT format.
    print_rank_0(f"[export] Writing HF PEFT adapter to {args.output}")
    bridge.save_hf_adapter(
        model,
        path=args.output,
        peft_config=lora_peft,
        base_model_name_or_path=args.hf_model,
        show_progress=(dist.get_rank() == 0),
    )

    dist.barrier()
    if dist.get_rank() == 0:
        out = Path(args.output)
        print("[export] Output contents:")
        for f in sorted(out.iterdir()):
            print(f"  {f.name:40s} {f.stat().st_size/1e6:.2f} MB")

    dist.destroy_process_group()


if __name__ == "__main__":
    main()
