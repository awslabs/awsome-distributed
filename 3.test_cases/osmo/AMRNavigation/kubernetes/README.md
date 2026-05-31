# AMR Navigation Pipeline on Kubernetes (Amazon EKS)

Step-by-step instructions for running the warehouse AMR navigation pipeline on Amazon EKS with NVIDIA OSMO orchestration.

## Prerequisites

1. **Amazon EKS cluster** with Kubernetes 1.29+ and Karpenter installed
2. **GPU nodes**: G5/G6 instances (rendering pool) + P-series (training pool) with NVIDIA GPU Operator
3. **NVIDIA OSMO** + **KAI Scheduler** installed
4. **NGC API key**: Sign up at [ngc.nvidia.com](https://ngc.nvidia.com/) and generate an API key
5. **S3 bucket** for inter-stage data with IRSA configured
6. **Tools**: `kubectl`, `docker`, `aws` CLI, `envsubst`, `osmo` CLI

### OSMO Control Plane Prerequisites

The pipeline requires OSMO control plane components. Follow the [NVIDIA OSMO installation guide](https://docs.nvidia.com/osmo/) to deploy OSMO on your EKS cluster, then verify readiness:

```bash
# Verify all OSMO components are ready
./4.verify-osmo.sh
```

### CPU-Only Smoke Test

Validate OSMO is working without GPU capacity:

```bash
# Via OSMO REST API (preferred — validates the full control plane path):
YAML=$(cat smoke-test-workflow.yaml)
kubectl -n osmo-system exec deploy/osmo-service -c service -- \
  python3 -c "
import requests, json, sys
resp = requests.post('http://localhost:8000/api/pool/default/workflow',
  json={'file': sys.stdin.read()})
print(json.dumps(resp.json(), indent=2))
" <<< "$YAML"

# Or via kubectl (bypasses OSMO API, only tests CRD processing):
kubectl apply -f smoke-test-workflow.yaml
kubectl get workflows -n isaac-sim -w
# Should complete in ~30 seconds
```

## Pipeline Architecture

The pipeline is split into two OSMO workflows:

### Data Pipeline (combination workflow)

Uses OSMO groups for parallel execution. Group 4 runs 3 render passes concurrently:

```
Group 1: scene-setup          (1 GPU, G-series)
    │
Group 2: spatial-analysis     (1 GPU, G-series)
    │
Group 3: trajectory-planning  (1 GPU, G-series)
    │
Group 4: multi-modal-render   (3 GPUs in parallel, G-series)
    ├── render-rgb
    ├── render-depth
    └── render-segmentation
    │
Group 5: domain-augmentation  (1 GPU, G-series)
```

### Training Workflow (single-task)

Runs independently on P-series Capacity Blocks:

```
train-evaluate  (8 GPUs, P-series)
  ├── World model pretraining
  └── Action policy fine-tuning
```

## Usage

### Step 1: Setup

```bash
export NGC_API_KEY="<your-ngc-api-key>"
./0.setup-ngc-secret.sh
```

### Step 2: Build All Images

```bash
./1.build-container.sh
```

This builds 3 pipeline images:
- `isaac-sim-amr:latest` (stages 1-4: scene setup, occupancy map, trajectory gen, rendering)
- `cosmos-transfer-amr:latest` (stage 5: domain augmentation)
- `xmobility-amr:latest` (stage 6: training + evaluation)

### Step 3: Submit Pipeline

```bash
export ISAAC_SIM_IMAGE_URI="<account>.dkr.ecr.<region>.amazonaws.com/isaac-sim-amr:latest"
export COSMOS_IMAGE_URI="<account>.dkr.ecr.<region>.amazonaws.com/cosmos-transfer-amr:latest"
export XMOBILITY_IMAGE_URI="<account>.dkr.ecr.<region>.amazonaws.com/xmobility-amr:latest"
export S3_BUCKET="my-amr-pipeline-bucket"
export RUN_ID="run-001"

# Submit both data pipeline + training
./3.submit-pipeline.sh

# Or submit data pipeline only
SKIP_TRAINING=true ./3.submit-pipeline.sh
```

### Step 4: Monitor

```bash
# OSMO workflow status
osmo workflow list
osmo workflow status amr-data-pipeline-${RUN_ID}
osmo workflow status amr-training-${RUN_ID}

# Watch pods (see parallel rendering in Group 4)
kubectl get pods -n isaac-sim -w

# Check specific task logs
osmo workflow logs amr-data-pipeline-${RUN_ID} --task render-rgb
osmo workflow logs amr-data-pipeline-${RUN_ID} --task render-depth
osmo workflow logs amr-training-${RUN_ID} --task train-evaluate
```

### Step 5: Verify Output

```bash
# List all stage outputs
aws s3 ls s3://${S3_BUCKET}/amr-pipeline/${RUN_ID}/ --recursive --summarize

# Multi-modal render outputs (produced in parallel)
aws s3 ls s3://${S3_BUCKET}/amr-pipeline/${RUN_ID}/rgb/
aws s3 ls s3://${S3_BUCKET}/amr-pipeline/${RUN_ID}/depth/
aws s3 ls s3://${S3_BUCKET}/amr-pipeline/${RUN_ID}/segmentation/

# Augmented data + training results
aws s3 ls s3://${S3_BUCKET}/amr-pipeline/${RUN_ID}/augmented/
aws s3 ls s3://${S3_BUCKET}/amr-pipeline/${RUN_ID}/results/
```

## File Reference

| File | Purpose |
|------|---------|
| `0.setup-ngc-secret.sh` | Create NGC image pull secret |
| `1.build-container.sh` | Build and push all container images |
| `3.submit-pipeline.sh` | Submit data pipeline + training workflows |
| `4.verify-osmo.sh` | Pre-flight check for OSMO control plane |
| `serviceaccount.yaml` | IRSA ServiceAccount for S3 access |
| `data-pipeline-workflow.yaml` | OSMO combination workflow (stages 1-5, parallel rendering) |
| `training-workflow.yaml` | OSMO single-task workflow (stage 6, P-series) |
| `amr-pipeline-workflow.yaml` | Full 6-stage sequential pipeline (reference) |
| `smoke-test-workflow.yaml` | CPU-only OSMO smoke test (no GPU needed) |

## Cleanup

```bash
# Cancel running workflows
osmo workflow cancel amr-data-pipeline-${RUN_ID}
osmo workflow cancel amr-training-${RUN_ID}

# Delete completed workflows
osmo workflow delete amr-data-pipeline-${RUN_ID}
osmo workflow delete amr-training-${RUN_ID}

# Full cleanup
kubectl delete namespace isaac-sim
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Pod stuck in `Pending` | No GPU nodes available | Check Karpenter NodePools for rendering (G-series) and training (P-series) |
| `ImagePullBackOff` | NGC auth failed | Verify `NGC_API_KEY` and re-run `0.setup-ngc-secret.sh` |
| `OOMKilled` | Insufficient memory | Use g5.4xlarge+ (64GB RAM) for Isaac Sim stages |
| Vulkan errors in logs | Missing GPU toolkit | Enable `toolkit.enabled=true` in GPU Operator values |
| Workflow timeout | Shader compilation slow | Increase `timeout` in workflow YAML |
| S3 `AccessDenied` | IRSA misconfigured | Check ServiceAccount annotation and IAM role trust policy |
| Group 4 only 1 pod | Karpenter scaling lag | Check NodePool limits — need 3 G-series GPUs for parallel render |
| Training NaN loss | Bad augmented data | Inspect augmented/ images, reduce learning rate |
