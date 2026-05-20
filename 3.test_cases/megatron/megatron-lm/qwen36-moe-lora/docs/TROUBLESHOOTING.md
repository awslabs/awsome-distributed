# Troubleshooting

Failure modes encountered during the reference run's bring-up, grouped by
phase. Each entry gives the symptom, root cause, and fix.

## Storage

### PVC stuck in Pending with FSx 2.10 error

Symptom in `kubectl describe pvc qwen-moe-lustre`:

```
Warning  ProvisioningFailed  ... filesystem version 2.10 not supported
```

**Root cause**: the default `fileSystemTypeVersion` on the FSx CSI driver
StorageClass is 2.10, which is incompatible with the Lustre 2.15.6 client
bundled in the p5e AMI. Mount attempts fail with kernel log
`Server MGS version (2.10.5.0) refused connection from this client with an
incompatible version (2.15.6)`.

**Fix**: `storage.yaml-template` explicitly sets `fileSystemTypeVersion: "2.15"`.
If you see this error, confirm the StorageClass applied cleanly:

```bash
kubectl get storageclass fsx-sc-215-$NAMESPACE -o yaml | grep fileSystemTypeVersion
```

### Mount fails with EINVAL (exit status 22) on p5e

Symptom: pod event `mount.lustre: ... failed: Invalid argument`.

**Root cause**: LNet kernel module not loaded. The HyperPod p5e AMI has the
Lustre client installed but doesn't auto-load the modules at boot.

**Fix**: ensure the node's lifecycle script loads Lustre modules:

```bash
modprobe lnet
modprobe lustre
lctl network up
```

For HyperPod, add this to `on_create_main.sh` before the cluster is created.
If you need to fix running nodes, run a privileged pod that execs
`nsenter --target 1 -- modprobe lnet && modprobe lustre` on each GPU host.

## Tokenizer

### Training crashes at iteration 1 with "NullTokenizer" error

Symptom:

```
NotImplementedError: This method is not supported for null-text tokenizers.
  at megatron/core/tokenizers/text/text_tokenizer.py:181  space_sensitive
```

**Root cause**: the Qwen3.5-VL recipe defaults to `NullTokenizer`, a stub used
for image-token pipelines. The text SFT dataset builder calls
`tokenizer.space_sensitive` which `NullTokenizer` doesn't implement.

**Fix**: already handled in `src/xlam_runner.py`:

```python
cfg.tokenizer.tokenizer_type = "HuggingFaceTokenizer"
cfg.tokenizer.tokenizer_model = "/fsx/hf_cache/models--Qwen--Qwen3.6-35B-A3B"
```

If you override the HF model path in `env.sh`, update the `tokenizer_model`
path too or expose it as another env var.

### Training fails with "Tokenizer path must be specified"

Symptom:

```
AssertionError: Tokenizer path must be specified.
  at megatron_tokenizer.py:85  from_pretrained
```

**Root cause**: `cfg.tokenizer.tokenizer_type = "HuggingFaceTokenizer"` was
set but `cfg.tokenizer.tokenizer_model` was not. Setting
`hf_tokenizer_kwargs` (as one might guess from HF convention) is NOT what
Bridge wants.

**Fix**: use `cfg.tokenizer.tokenizer_model = <path-or-hf-id>`.

## Checkpoint

### Training crashes with "Invalid pretrained checkpoint directory"

Symptom:

```
ValueError: Invalid pretrained checkpoint directory found: /fsx/hf_cache/...
```

**Root cause**: `cfg.checkpoint.pretrained_checkpoint` points at raw HF
safetensors. Bridge expects its own distributed-checkpoint format
(`metadata.json` + sharded `.distcp` files).

**Fix**: run `./scripts/3.convert-to-bridge.sh` first, which runs
`convert_checkpoints_multi_gpu.py import`. The resulting `/fsx/qwen36-bridge/`
is what `PRETRAINED_CHECKPOINT` should point at.

### Export fails with "cuda rng state model-parallel-rng is not added"

Symptom (during `./scripts/5.export-adapter.sh`):

```
Exception: cuda rng state model-parallel-rng is not added
  at megatron/core/tensor_parallel/random.py:303  fork
```

**Root cause**: Megatron's TP-aware RNG was not seeded before the first
transformer layer was built.

**Fix**: already handled in `src/export_lora_adapter.py` by calling
`provider.initialize_model_parallel(seed=0)`, which internally calls
`model_parallel_cuda_manual_seed`. Verify if you customized the export script.

### Export fails with "Different dict keys encountered in apply_factory_merges"

Symptom (during `./scripts/5.export-adapter.sh`):

```
ValueError: Different dict keys encountered in apply_factory_merges
  (checkpoint has: vision_model.*, optimizer.*, scheduler.*, content_metadata, ...)
```

**Root cause**: raw `dist_checkpointing.load(sharded_state_dict)` can't
reconcile the training checkpoint's extra keys (VL-recipe vision adapters +
optimizer state + scheduler + metadata) against a filtered state dict that
expects language-model adapter keys only.

**Fix**: `src/export_lora_adapter.py` uses
`_generate_model_state_dict` + `apply_peft_adapter_filter_to_state_dict` to
produce an adapter-only filtered state dict before loading (the pattern
from `examples/peft/merge_lora.py` in the Megatron-Bridge repo). Verify the
filter is applied if you modify the script.

## Inference

### vLLM pod OOM at model load

Symptom: `CUDA out of memory ... GPU 0 has a total capacity of 22.03 GiB`.

**Root cause**: pod scheduled on a 24 GB L4 or A10G node instead of a p5e/p5
H100/H200 node. Qwen3.6-35B bf16 is ~28 GB of weights — can't fit on a single
24 GB GPU, needs at least 2× 80 GB (H100) or 2× 141 GB (H200) via
`--tensor-parallel-size`.

**Fix**: the inference manifest pins `nodeSelector:
node.kubernetes.io/instance-type: ${NODE_INSTANCE_TYPE}` where
`NODE_INSTANCE_TYPE=ml.p5e.48xlarge` in `env.sh`. Don't override to a smaller
type for inference; the base model needs its HBM.


### HF lockfile read-only filesystem error at vLLM startup

Symptom:

```
OSError: [Errno 30] Read-only file system:
'/fsx/hf_cache/hub/.locks/...'
```

**Root cause**: vLLM writes HuggingFace cache lockfiles into the PVC mount. If
mounted read-only, every config lookup fails.

**Fix**: the inference manifest mounts Lustre read-write. The base model
weights are append-only by construction (no vLLM code writes to them); only
`.locks/` bookkeeping gets written. Don't set `readOnly: true` on the PVC
mount for vLLM.

### Both models emit reasoning prose but no tool call

Symptom: `content` contains `Thinking Process: ... 1. Analyze input ...` but
no `<tool_call>` tags.

**Root cause**: Qwen3.6 defaults to "thinking mode" — generates a `<think>`
CoT preamble before any action. The token budget runs out before the tool
call is emitted.

**Fix**: every request must include
`"chat_template_kwargs": {"enable_thinking": False}`. The
`src/eval_function_calling.py` helper does this automatically.

