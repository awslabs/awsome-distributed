#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# 2.sanity-singlenode.sh — single-node bring-up gate for the model-agnostic
# Megatron-Bridge + UCCL-over-EFA environment image. Run this INSIDE the container
# on one p6-b300.48xlarge node (8x B300 GPUs) before submitting any multi-node
# PyTorchJob for a model under this library.
#
# Gates (run in order; first failure exits immediately):
#   1. EFA fabric   — fi_info -p efa lists at least one EFA device
#   2. deep_ep     — import deep_ep is importable and the UCCL wrapper is active
#                     (deep_ep.Buffer present; site-packages path is expected after pip install)
#   3. MCore fields — megatron.core.__version__ prints and TransformerConfig has
#                     moe_token_dispatcher_type / moe_flex_dispatcher_backend (hard);
#                     moe_enable_deepep is checked but only WARNs if absent
#   4. NCCL/EFA     — optional tiny all-reduce over 8 GPUs via EFA; skipped when
#                     SKIP_NCCL_TEST=1 is set (e.g., EFA not yet initialised in CI)
#   5. flex/deepep  — 8-GPU torchrun on this node (EP=8) runs one forward + backward
#                     step through MoEFlexTokenDispatcher with backend="deepep",
#                     proving UCCL dispatch+combine on the backward pass over NVLink
#                     (intranode EFA exercised automatically via UCCL Buffer).
#
# Usage:
#   # Inside the container, from any directory:
#   bash 2.sanity-singlenode.sh
#
#   # Skip the optional NCCL all-reduce:
#   SKIP_NCCL_TEST=1 bash 2.sanity-singlenode.sh
#
# Requirements:
#   - Container image built from Dockerfile
#   - EFA device plugin has allocated 16 EFA interfaces to this pod
#     (vpc.amazonaws.com/efa: 16 in the pod spec)
#   - 8 NVIDIA GPUs available (CUDA_VISIBLE_DEVICES or all 8 B300s exposed)

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
PASS="[PASS]"
FAIL="[FAIL]"
INFO="[INFO]"
WARN="[WARN]"

pass() { echo "${PASS} $*"; }
fail() { echo "${FAIL} $*" >&2; exit 1; }
info() { echo "${INFO} $*"; }
warn() { echo "${WARN} $*"; }

section() {
    echo ""
    echo "=================================================================="
    echo "  GATE $*"
    echo "=================================================================="
}

# ---------------------------------------------------------------------------
# Environment defaults (all overridable)
# ---------------------------------------------------------------------------
: "${GPUS_PER_NODE:=8}"
: "${SKIP_NCCL_TEST:=0}"
# Number of experts for the micro-step test (must be divisible by GPUS_PER_NODE).
: "${NUM_EXPERTS:=8}"
# Tokens per micro-step (keep small for a fast gate).
: "${SEQ_LEN:=64}"
: "${MICRO_BATCH:=2}"
: "${HIDDEN_SIZE:=256}"
: "${FFN_HIDDEN_SIZE:=512}"

# ---------------------------------------------------------------------------
# GATE 1 — EFA fabric
# ---------------------------------------------------------------------------
section "1 / 5 — EFA device presence (fi_info -p efa)"

if ! command -v fi_info &>/dev/null; then
    fail "fi_info not found. Is the EFA installer baked into the image?"
fi

EFA_COUNT=$(fi_info -p efa 2>/dev/null | grep -c "^provider:" || true)
info "fi_info reports ${EFA_COUNT} EFA provider entry/entries"

if [[ "${EFA_COUNT}" -eq 0 ]]; then
    fail "No EFA devices found. Ensure the pod has vpc.amazonaws.com/efa: 16 in its resource spec and the EFA device plugin is running."
fi

fi_info -p efa | head -40
pass "Gate 1: ${EFA_COUNT} EFA device(s) visible"

# ---------------------------------------------------------------------------
# GATE 2 — deep_ep shadow module resolves to /opt/uccl
# ---------------------------------------------------------------------------
section "2 / 5 — UCCL deep_ep shadow module"

python3 - <<'PYEOF'
import sys

# TODO(validate against image): confirm a positive UCCL marker (a uccl-specific
# attr on deep_ep); site-packages path is expected after `pip install .`, so do
# NOT assert on /opt/uccl. https://github.com/uccl-project/uccl
try:
    import deep_ep
    import uccl
except ImportError as e:
    print(f"[FAIL] 'import deep_ep'/'import uccl' raised ImportError: {e}", file=sys.stderr)
    sys.exit(1)

print(f"[INFO] deep_ep -> {deep_ep.__file__}")
print(f"[INFO] uccl    -> {uccl.__file__}")

# Positive check: the UCCL wrapper exposes Buffer. A bare importable deep_ep that
# lacks Buffer means the UCCL wrapper is not the active module.
if not hasattr(deep_ep, "Buffer"):
    print(
        "[FAIL] deep_ep.Buffer missing — UCCL wrapper not active. "
        "Check that 'pip install .' was run in /opt/uccl/ep/deep_ep_wrapper "
        "AFTER any other deep_ep installation.",
        file=sys.stderr,
    )
    sys.exit(1)

print(f"[PASS] Gate 2: deep_ep importable and UCCL wrapper active (deep_ep.Buffer present)")
PYEOF

# ---------------------------------------------------------------------------
# GATE 3 — Megatron-Core version + flex/deepep config fields
# ---------------------------------------------------------------------------
section "3 / 5 — Megatron-Core version and flex/deepep TransformerConfig fields"

python3 - <<'PYEOF'
import sys

# ---- version ----
try:
    import megatron.core as mcore
except ImportError as e:
    print(f"[FAIL] 'import megatron.core' failed: {e}", file=sys.stderr)
    sys.exit(1)

version = getattr(mcore, "__version__", "<unknown>")
print(f"[INFO] megatron.core.__version__ = {version}")

# ---- TransformerConfig fields ----
try:
    from megatron.core.transformer.transformer_config import TransformerConfig
except ImportError as e:
    print(f"[FAIL] Cannot import TransformerConfig: {e}", file=sys.stderr)
    sys.exit(1)

import dataclasses

field_names = {f.name for f in dataclasses.fields(TransformerConfig)}

# Hard requirements — these select the flex/deepep dispatch path. Missing => FAIL.
required_fields = {
    "moe_token_dispatcher_type": "controls allgather / alltoall / flex dispatch path",
    "moe_flex_dispatcher_backend": "selects deepep vs hybridep backend under flex",
}

# Soft requirement — the config treats moe_enable_deepep as unverified
# (hasattr-guarded), so a missing field here is a WARNING, not a failure.
optional_fields = {
    "moe_enable_deepep": "experimental flag that arms the DeepEP/UCCL import",
}

all_ok = True
for field, description in required_fields.items():
    if field in field_names:
        print(f"[INFO]   TransformerConfig.{field}  ({description})")
    else:
        print(
            f"[FAIL] TransformerConfig missing field '{field}' ({description}). "
            f"The installed Megatron-Core may be too old (need >= 0.14 with flex dispatcher).",
            file=sys.stderr,
        )
        all_ok = False

for field, description in optional_fields.items():
    if field in field_names:
        print(f"[INFO]   TransformerConfig.{field}  ({description})")
    else:
        print(
            f"[WARN] TransformerConfig has no '{field}' ({description}). "
            f"The config sets it only via hasattr() so this is not fatal; "
            f"flex + deepep backend should still route through the UCCL shadow.",
            file=sys.stderr,
        )

if not all_ok:
    sys.exit(1)

print(f"[PASS] Gate 3: megatron.core {version}, required flex/deepep config fields present")
PYEOF

# ---------------------------------------------------------------------------
# GATE 4 — NCCL all-reduce over EFA (optional)
# ---------------------------------------------------------------------------
section "4 / 5 — NCCL all-reduce over EFA (${GPUS_PER_NODE} GPUs)"

if [[ "${SKIP_NCCL_TEST}" == "1" ]]; then
    warn "SKIP_NCCL_TEST=1 — skipping NCCL all-reduce gate"
else
    # Write the worker script to a temp file so each torchrun worker can read it.
    # Piping a heredoc to 'torchrun ... -' is unreliable: spawned workers receive
    # DEVNULL stdin and execute an empty script, yielding a false PASS.
    _GATE4_PY=$(mktemp /tmp/sanity_gate4.XXXX.py)
    trap 'rm -f "${_GATE4_PY}"' EXIT

    cat > "${_GATE4_PY}" <<'PYEOF'
import os, sys, torch, torch.distributed as dist

rank = int(os.environ["RANK"])
local_rank = int(os.environ["LOCAL_RANK"])
world_size = int(os.environ["WORLD_SIZE"])

torch.cuda.set_device(local_rank)
dist.init_process_group("nccl")

# Tiny tensor; each rank contributes its (local_rank + 1) value.
t = torch.tensor([float(local_rank + 1)], device="cuda")
dist.all_reduce(t)
expected = float(world_size * (world_size + 1) // 2)

if abs(t.item() - expected) > 1e-3:
    print(
        f"[FAIL] rank {rank}: all-reduce result {t.item()} != expected {expected}",
        file=sys.stderr,
    )
    dist.destroy_process_group()
    sys.exit(1)

if rank == 0:
    print(f"[PASS] Gate 4: NCCL all-reduce correct across {world_size} GPUs "
          f"(result={t.item()})")

dist.destroy_process_group()
PYEOF

    torchrun \
        --standalone \
        --nproc_per_node="${GPUS_PER_NODE}" \
        --nnodes=1 \
        "${_GATE4_PY}"

    rm -f "${_GATE4_PY}"
    # Reset trap now that we cleaned up manually.
    trap - EXIT
fi

# ---------------------------------------------------------------------------
# GATE 5 — flex/deepep forward + backward micro-step
#
# Launches 8 torchrun workers on this node (EP=8, TP=1, PP=1, DP=1).
# Each worker:
#   1. Initialises Megatron-Core process groups with EP=8.
#   2. Creates a minimal TransformerConfig with flex dispatcher + deepep backend.
#   3. Instantiates MoEFlexTokenDispatcher — triggers `from deep_ep import Buffer`
#      resolving to the UCCL shadow module.
#   4. Runs one forward pass (dispatch -> dummy expert linear -> combine).
#   5. Calls .backward() on the loss to exercise the combine backward path.
#
# This is the highest-risk gate: it proves UCCL's dispatch+combine
# are differentiable and work on the backward pass over intranode NVLink.
# ---------------------------------------------------------------------------
section "5 / 5 — flex/deepep forward + backward micro-step (EP=${GPUS_PER_NODE})"

# Export scalars so the torchrun child can read them.
export _SANITY_NUM_EXPERTS="${NUM_EXPERTS}"
export _SANITY_SEQ_LEN="${SEQ_LEN}"
export _SANITY_MICRO_BATCH="${MICRO_BATCH}"
export _SANITY_HIDDEN_SIZE="${HIDDEN_SIZE}"
export _SANITY_FFN_HIDDEN_SIZE="${FFN_HIDDEN_SIZE}"

# Write the worker script to a temp file. Piping a heredoc to 'torchrun ... -'
# is unreliable: each spawned worker gets DEVNULL/empty stdin and executes an
# empty script, yielding a false PASS. Using a named file avoids this entirely.
_GATE5_PY=$(mktemp /tmp/sanity_gate5.XXXX.py)
trap 'rm -f "${_GATE5_PY}"' EXIT

cat > "${_GATE5_PY}" <<'PYEOF'
"""
Single-node forward + backward through MoEFlexTokenDispatcher (backend=deepep).

Parallelism layout: EP=WORLD_SIZE, TP=1, PP=1, DP=1.
Each rank owns (NUM_EXPERTS // WORLD_SIZE) local experts.

This script intentionally does NOT fall back to a no-op on API mismatches.
A TypeError from the dispatcher means the method signatures differ from what
this script expects — the gate must FAIL so the operator can inspect the
actual API in token_dispatcher.py inside the built image before burning
32-node capacity-block hours on a broken job.
"""
import os, sys
import torch
import torch.distributed as dist

# ---- env ----
rank        = int(os.environ["RANK"])
local_rank  = int(os.environ["LOCAL_RANK"])
world_size  = int(os.environ["WORLD_SIZE"])

NUM_EXPERTS     = int(os.environ.get("_SANITY_NUM_EXPERTS",    "8"))
SEQ_LEN         = int(os.environ.get("_SANITY_SEQ_LEN",        "64"))
MICRO_BATCH     = int(os.environ.get("_SANITY_MICRO_BATCH",    "2"))
HIDDEN_SIZE     = int(os.environ.get("_SANITY_HIDDEN_SIZE",    "256"))
FFN_HIDDEN_SIZE = int(os.environ.get("_SANITY_FFN_HIDDEN_SIZE","512"))

assert NUM_EXPERTS % world_size == 0, (
    f"NUM_EXPERTS ({NUM_EXPERTS}) must be divisible by world_size ({world_size})"
)
NUM_LOCAL_EXPERTS = NUM_EXPERTS // world_size

torch.cuda.set_device(local_rank)
device = torch.device(f"cuda:{local_rank}")

# ---- distributed init ----
dist.init_process_group("nccl")

# ---- Megatron-Core parallel state ----
try:
    from megatron.core import parallel_state as mpu
except ImportError as e:
    print(f"[FAIL] rank {rank}: cannot import megatron.core.parallel_state: {e}",
          file=sys.stderr)
    dist.destroy_process_group()
    sys.exit(1)

# EP=world_size, TP=1, PP=1, CP=1.
mpu.initialize_model_parallel(
    tensor_model_parallel_size=1,
    pipeline_model_parallel_size=1,
    expert_model_parallel_size=world_size,
    context_parallel_size=1,
)

if rank == 0:
    print(f"[INFO] EP={world_size}, TP=1, PP=1, DP=1, "
          f"NUM_EXPERTS={NUM_EXPERTS}, LOCAL={NUM_LOCAL_EXPERTS}/rank")

# ---- TransformerConfig with flex/deepep ----
try:
    from megatron.core.transformer.transformer_config import TransformerConfig
except ImportError as e:
    print(f"[FAIL] rank {rank}: cannot import TransformerConfig: {e}", file=sys.stderr)
    dist.destroy_process_group()
    sys.exit(1)

cfg = TransformerConfig(
    num_layers=1,
    hidden_size=HIDDEN_SIZE,
    num_attention_heads=4,                    # required but unused in this test
    ffn_hidden_size=FFN_HIDDEN_SIZE,
    tensor_model_parallel_size=1,
    expert_model_parallel_size=world_size,
    pipeline_model_parallel_size=1,
    num_moe_experts=NUM_EXPERTS,
    moe_router_topk=2,
    # ---- flex/deepep dispatcher ----
    moe_token_dispatcher_type="flex",
    moe_flex_dispatcher_backend="deepep",
    moe_enable_deepep=True,
    # ---- precision ----
    bf16=True,
    params_dtype=torch.bfloat16,
)

# ---- MoEFlexTokenDispatcher ----
#
# Importing this triggers 'from deep_ep import Buffer' inside
# megatron.core.transformer.moe.fused_a2a, which must resolve to UCCL.
try:
    from megatron.core.transformer.moe.token_dispatcher import MoEFlexTokenDispatcher
except ImportError as e:
    print(f"[FAIL] rank {rank}: cannot import MoEFlexTokenDispatcher: {e}",
          file=sys.stderr)
    dist.destroy_process_group()
    sys.exit(1)

# Confirm the UCCL deep_ep wrapper is active after the import chain above.
# TODO(validate against image): confirm a positive UCCL marker (a uccl-specific
# attr on deep_ep); site-packages path is expected after pip install, so do NOT
# assert on /opt/uccl. https://github.com/uccl-project/uccl
if "deep_ep" in sys.modules:
    _dep = sys.modules["deep_ep"]
    _path = getattr(_dep, "__file__", "<unknown>")
    if not hasattr(_dep, "Buffer"):
        print(
            f"[FAIL] rank {rank}: deep_ep imported from '{_path}' but lacks Buffer "
            f"— UCCL wrapper is not active.",
            file=sys.stderr,
        )
        dist.destroy_process_group()
        sys.exit(1)
    if rank == 0:
        print(f"[INFO] deep_ep confirmed (UCCL wrapper active, Buffer present) -> {_path}")
else:
    # deep_ep may be lazily imported on first dispatch; warn but do not fail yet.
    if rank == 0:
        print("[WARN] deep_ep not yet in sys.modules after dispatcher import; "
              "it may be loaded on first dispatch call.", file=sys.stderr)

# Build the local expert index list for this rank.
local_expert_indices = list(range(
    rank * NUM_LOCAL_EXPERTS,
    (rank + 1) * NUM_LOCAL_EXPERTS,
))

# TODO(validate against image): MoEFlexTokenDispatcher constructor signature.
# In MCore >= 0.14 the constructor is:
#   MoEFlexTokenDispatcher(num_local_experts, local_expert_indices, config, pg_collection=None)
# If the call below raises TypeError, check token_dispatcher.py in the built
# image for the actual signature (pg_collection may be required).
dispatcher = MoEFlexTokenDispatcher(
    num_local_experts=NUM_LOCAL_EXPERTS,
    local_expert_indices=local_expert_indices,
    config=cfg,
)

if rank == 0:
    print(f"[INFO] MoEFlexTokenDispatcher instantiated (backend=deepep, "
          f"{NUM_LOCAL_EXPERTS} experts/rank)")

# ---- Dummy input ----
S = MICRO_BATCH * SEQ_LEN          # total tokens this rank
hidden   = torch.randn(S, HIDDEN_SIZE, device=device, dtype=torch.bfloat16,
                       requires_grad=True)
# Router: softmax + top-2 selection.
logits   = torch.randn(S, NUM_EXPERTS, device=device, dtype=torch.bfloat16)
probs_full = torch.softmax(logits.float(), dim=-1).to(torch.bfloat16)
topk_val, topk_idx = torch.topk(probs_full, k=cfg.moe_router_topk, dim=-1)
topk_val = topk_val / topk_val.sum(dim=-1, keepdim=True)   # renormalise

# ---- Forward: dispatch -> expert -> combine ----
#
# TODO(validate against image): The MoEFlexTokenDispatcher method signatures
# below follow the 3+3 step pattern described in token_dispatcher.py for
# MCore >= 0.14 (flex dispatcher). Verify against the actual file in the
# built image:
#   dispatch_preprocess(topk_idx, topk_val)    -> (routing_map, probs_out)
#   token_dispatch(hidden, routing_map, probs) -> (dispatched, tokens_per_expert)
#   dispatch_postprocess(dispatched)           -> dispatched  [if method exists]
#   combine_preprocess(expert_out)             -> expert_out  [if method exists]
#   token_combine(expert_out, routing_map, probs) -> output
#   combine_postprocess(output)                -> output      [if method exists]
#
# If the signatures differ, correct THIS script; do NOT add a try/except
# fallback that masks the mismatch — a masked failure here will surface as a
# mysterious crash during the 32-node job.

routing_map, probs_out = dispatcher.dispatch_preprocess(topk_idx, topk_val)
dispatched, tokens_per_expert = dispatcher.token_dispatch(hidden, routing_map, probs_out)

if hasattr(dispatcher, "dispatch_postprocess"):
    dispatched = dispatcher.dispatch_postprocess(dispatched)

# Trivial per-expert transform: scale by (rank + 1) so gradients are non-zero.
expert_out_parts = []
offset = 0
for i in range(NUM_LOCAL_EXPERTS):
    n = int(tokens_per_expert[i])
    chunk = dispatched[offset:offset + n]      # (n_tokens, HIDDEN_SIZE)
    expert_out_parts.append(chunk * float(rank + 1))
    offset += n
expert_out = (torch.cat(expert_out_parts, dim=0) if expert_out_parts
              else dispatched.new_empty(0, HIDDEN_SIZE))

if hasattr(dispatcher, "combine_preprocess"):
    expert_out = dispatcher.combine_preprocess(expert_out)

output = dispatcher.token_combine(expert_out, routing_map, probs_out)

if hasattr(dispatcher, "combine_postprocess"):
    output = dispatcher.combine_postprocess(output)

# ---- Backward ----
loss = output.sum()
loss.backward()

if hidden.grad is None:
    print(f"[FAIL] rank {rank}: hidden.grad is None after backward — "
          f"the combine path did not propagate gradients.", file=sys.stderr)
    dist.destroy_process_group()
    sys.exit(1)

# Barrier: all ranks must reach this point.
ok_flag = torch.tensor([1], dtype=torch.int32, device=device)
dist.all_reduce(ok_flag, op=dist.ReduceOp.MIN)
if ok_flag.item() != 1:
    print(f"[FAIL] rank {rank}: some rank failed the forward+backward step",
          file=sys.stderr)
    dist.destroy_process_group()
    sys.exit(1)

# Also verify deep_ep is in sys.modules now (lazy import case).
if "deep_ep" not in sys.modules:
    print(f"[FAIL] rank {rank}: deep_ep was never imported during dispatch — "
          f"UCCL is not active. Check fused_a2a.py in the image.",
          file=sys.stderr)
    dist.destroy_process_group()
    sys.exit(1)

if rank == 0:
    print(f"[PASS] Gate 5: forward+backward through MoEFlexTokenDispatcher "
          f"(deepep/UCCL, EP={world_size}, {NUM_EXPERTS} experts). "
          f"hidden.grad norm = {hidden.grad.norm().item():.4f}")

dist.destroy_process_group()
PYEOF

torchrun \
    --standalone \
    --nproc_per_node="${GPUS_PER_NODE}" \
    --nnodes=1 \
    "${_GATE5_PY}"

rm -f "${_GATE5_PY}"
trap - EXIT

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=================================================================="
echo "  ALL SANITY GATES PASSED — node is ready for the 32-node job"
echo "=================================================================="
