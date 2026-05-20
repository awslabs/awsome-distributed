# Qwen3.6-35B-A3B Function-Calling LoRA on Kubernetes

End-to-end LoRA fine-tuning of Qwen3.6-35B-A3B, a 256-expert Mixture-of-Experts
model, for structured tool-call generation on the xLAM-60k dataset. Runs on 2×
p5e.48xlarge (16× H200) using Megatron-Bridge with tensor, expert, and data
parallelism; serves the trained adapter with vLLM; evaluates against the base
model on hand-crafted edge cases and LLM-as-judge over held-out validation.

Works on any Kubernetes cluster with the NVIDIA device plugin and the EFA
device plugin — tested on **Amazon SageMaker HyperPod (EKS mode)** and plain
**Amazon EKS** with FSx for Lustre storage.


## Model, dataset, and result

| | |
|---|---|
| Base model | [`Qwen/Qwen3.6-35B-A3B`](https://huggingface.co/Qwen/Qwen3.6-35B-A3B) (256 experts, top-8 routing, ~3B active) |
| Dataset | [`minpeter/xlam-function-calling-60k-parsed`](https://huggingface.co/datasets/minpeter/xlam-function-calling-60k-parsed) (58.8k train / 1.2k val, 3,673 unique tool schemas) |
| Technique | LoRA rank 64, alpha 128, target `linear_qkv` + `linear_proj` only |
| Parallelism | TP=2, PP=1, EP=4, DP=2 on 16 H200 |
| Trained | 4,200 iterations, ~413M tokens, ~3.43 epochs |
| Reference adapter | [`ying2022/qwen3-6-35b-xlam-tools-lora`](https://huggingface.co/ying2022/qwen3-6-35b-xlam-tools-lora) (108 MB, published) |
| Observed wall-clock | 2h 12min end-to-end |
| Gate 1 result | Base 6/10 → LoRA 9/10 (+30 pp absolute) |
| Gate 2 result | LoRA wins 47/50 (94%) judged by Claude Opus 4.7 |

You can skip training entirely and serve the published adapter from
HuggingFace by setting `LORA_SOURCE=hf` in your environment (see step 6).

## Prerequisites

- **Kubernetes cluster** with 2× p5e.48xlarge (or p5.48xlarge) GPU nodes in the
  same availability zone. Both EKS and HyperPod EKS work; reference setup for
  HyperPod EKS is in
  [`1.architectures/7.sagemaker-hyperpod-eks/`](../../../../../1.architectures/7.sagemaker-hyperpod-eks/).
- **NVIDIA device plugin** and **EFA device plugin** installed on the cluster.
- **Kubeflow Training Operator v1.9.0** or later
  (`kubectl apply -k "github.com/kubeflow/training-operator/manifests/overlays/standalone?ref=v1.9.1"`).
- **FSx for Lustre CSI driver**
  (`helm install fsx-csi -n kube-system aws-fsx-csi-driver/aws-fsx-csi-driver`) and
  an AWS subnet + security group that allows Lustre protocol (TCP 988, 1021-1023).
- **AWS CLI + kubectl + envsubst + helm** locally.
- **Optional**: HuggingFace token for gated models, stored as a Kubernetes
  Secret named `hf-token` in the target namespace.
- **Optional (for Gate 2 eval)**: IAM role with `bedrock:InvokeModel` permission
  on the Claude Opus 4.7 inference profile, attached via IRSA to the default
  ServiceAccount in the test-case namespace.

## Instance options

| Instance | GPUs | HBM per GPU | Notes |
|---|---|---|---|
| `ml.p5e.48xlarge` × 2 | 8× H200 | 141 GB | Reference configuration; best MFU |
| `ml.p5.48xlarge` × 2 | 8× H100 | 80 GB | Works; slightly tighter memory headroom |
| `ml.p4de.24xlarge` × 2 | 8× A100 | 80 GB | Works; ~2-3× slower (no FP8, older SM) |

For p5 or p4de, update `NODE_INSTANCE_TYPE` and `EFA_PER_NODE` in
`kubernetes/scripts/env.sh` (p5 has 32 EFA NICs like p5e; p4de has 4).

## Walkthrough

Every step is a numbered script in `kubernetes/scripts/`. Each script is
idempotent — re-running applies updated manifests without tearing down
existing state.

```bash
cd 3.test_cases/megatron/megatron-lm/qwen36-moe-lora
cp kubernetes/scripts/env.example kubernetes/scripts/env.sh
# edit kubernetes/scripts/env.sh: set FSX_SUBNET_ID, FSX_SECURITY_GROUP, node type, etc.
source kubernetes/scripts/env.sh
```

### 0. Setup storage (~15 min, one-time)

```bash
./kubernetes/scripts/0.setup-storage.sh
```

Creates namespace, FSx Lustre StorageClass (version 2.15 — **critical**: the
FSx default of 2.10 is incompatible with the p5e AMI's Lustre client), PVC
`qwen-moe-lustre`, and a ConfigMap holding the Python scripts.

### 1. Pre-cache base weights (~30 min, one-time)

```bash
./kubernetes/scripts/1.precache-weights.sh
```

Downloads the ~70 GB Qwen3.6-35B safetensors to Lustre. Subsequent training
runs and inference deployments read from here instead of re-downloading.

### 2. Prepare dataset (~2 min)

```bash
./kubernetes/scripts/2.prep-dataset.sh
```

Converts the HuggingFace xLAM-60k parquet into
`/fsx/datasets/training.jsonl` + `/fsx/datasets/validation.jsonl` in the
format Megatron-Bridge's `llm-finetune-preloaded` dataset builder expects.

### 3. Convert HF weights to Megatron-Bridge format (~25 min, one-time)

```bash
./kubernetes/scripts/3.convert-to-bridge.sh
```

Megatron-Bridge reads its own distributed checkpoint format
(`metadata.json` + sharded `.distcp` files), not HuggingFace safetensors. This
script runs `convert_checkpoints_multi_gpu.py import` with the same TP/PP/EP
sharding the training job will use.

The output at `/fsx/qwen36-bridge/` is reusable — as long as you don't change
`TP`, `PP`, or `EP`, you can re-train without rerunning this step.

### 4. Train (~2h 12min on 16× H200)

```bash
./kubernetes/scripts/4.train.sh
```

Submits a Kubeflow `PyTorchJob` with `replicas=NUM_NODES` Workers, each
running `torchrun --nproc_per_node=GPU_PER_NODE` for a total of 16 ranks.
Refreshes the ConfigMap before submission so any local edits to
`src/xlam_runner.py` are picked up.

Watch with:

```bash
kubectl -n $NAMESPACE logs -f qwen36-xlam-train-worker-0
```

The training prints `Step Time: Xs GPU utilization: Y MODEL_TFLOP/s/GPU` every
10 iterations and saves a checkpoint every 500 iterations to
`/fsx/qwen36-xlam-runs/checkpoints/iter_XXXXXXX`.

### 5. Export adapter to HuggingFace PEFT format (~10 min)

```bash
./kubernetes/scripts/5.export-adapter.sh
```

Converts the Megatron distributed checkpoint to a standard HF PEFT adapter
(`adapter_config.json` + `adapter_model.safetensors`, total ~108 MB) at
`/fsx/qwen36-xlam-runs/adapter_hf/`. This artifact is portable — you can
upload it to the HuggingFace Hub and load it from any PEFT-compatible runtime.

### 6. Deploy inference (~8 min cold start)

```bash
./kubernetes/scripts/6.deploy-inference.sh
```

Creates a vLLM Deployment + ClusterIP Service serving the base model with
the adapter loaded under the alias `tools`. Exposes an OpenAI-compatible API
at `http://qwen-inference.$NAMESPACE.svc.cluster.local:8000/v1/`.

**To skip training and use the published reference adapter** instead, set in
`env.sh`:

```bash
export LORA_SOURCE=hf
export LORA_REPO=ying2022/qwen3-6-35b-xlam-tools-lora
```

### 7. Run evaluation

```bash
# Gate 1 (10 prompts, ~2 min, no external dependencies):
export GATE=1
./kubernetes/scripts/7.run-eval.sh

# Gate 2 (50 prompts via Claude Opus 4.7, ~4 min, requires Bedrock):
export GATE=2
./kubernetes/scripts/7.run-eval.sh

# Both gates:
export GATE=all
./kubernetes/scripts/7.run-eval.sh
```

Results print at the end of the Job's logs:

```
=== Summary ===
  gate1_base             6/10
  gate1_lora             9/10
  gate2_lora_wins        47/50
  gate2_win_rate         94%
```

### Cleanup

```bash
./kubernetes/scripts/cleanup.sh
# Preserves the Lustre PVC (and all cached weights, checkpoints, adapter).
# To also delete the filesystem:
kubectl -n $NAMESPACE delete pvc qwen-moe-lustre
```

## Directory layout

```
qwen36-moe-lora/
├── README.md                       # this file
├── src/                            # platform-agnostic Python (training, eval, export)
│   ├── prep_xlam_dataset.py        # xLAM parquet → Megatron JSONL
│   ├── xlam_runner.py              # Megatron-Bridge training driver
│   ├── export_lora_adapter.py      # distcp → HF PEFT converter
│   └── eval_function_calling.py    # Gate 1 + Gate 2 eval
├── docs/
│   ├── PERFORMANCE.md              # observed step time, MFU, memory, EP topology
│   ├── EVALUATION.md               # 2-gate methodology + full results
│   └── TROUBLESHOOTING.md          # common failure modes and fixes
└── kubernetes/
    ├── manifests/
    │   ├── storage.yaml-template
    │   ├── 0.precache-weights.yaml-template
    │   ├── 1.prep-dataset.yaml-template
    │   ├── 2.convert-to-bridge.yaml-template
    │   ├── 3.pytorchjob-train.yaml-template
    │   ├── 4.export-adapter.yaml-template
    │   ├── 5.inference-vllm.yaml-template
    │   └── 6.eval-job.yaml-template
    └── scripts/
        ├── env.example             # copy to env.sh; holds cluster-specific config
        ├── 0.setup-storage.sh
        ├── 1.precache-weights.sh
        ├── 2.prep-dataset.sh
        ├── 3.convert-to-bridge.sh
        ├── 4.train.sh
        ├── 5.export-adapter.sh
        ├── 6.deploy-inference.sh
        ├── 7.run-eval.sh
        └── cleanup.sh
```

## Further reading

- [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md) — observed performance, MFU,
  memory usage, and EP topology analysis
- [`docs/EVALUATION.md`](docs/EVALUATION.md) — evaluation methodology and the
  reference run's full results
- [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) — common failures
  during bring-up (FSx Lustre version mismatch, tokenizer defaults, etc.)
- [Megatron-Bridge repo](https://github.com/NVIDIA/Megatron-Bridge) for the
  recipe catalog and API reference
- [xLAM paper](https://arxiv.org/abs/2409.03215) — dataset provenance
