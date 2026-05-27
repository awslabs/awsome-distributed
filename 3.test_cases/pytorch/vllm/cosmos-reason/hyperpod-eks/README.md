# Cosmos Reason on the SageMaker HyperPod Inference Operator

`InferenceEndpointConfig` CRD reference for serving Cosmos Reason on a SageMaker HyperPod
EKS cluster using the [HyperPod Inference Operator](https://aws.amazon.com/blogs/architecture/unlock-efficient-model-deployment-simplified-inference-operator-setup-on-amazon-sagemaker-hyperpod/).

This path uses the **AWS-managed vLLM Deep Learning Container** (`vllm:0.17-gpu-py312`)
with EFA, NCCL, and security patches pre-baked. The DLC tag `0.17-gpu-py312` corresponds
to vLLM 0.17.1; the [`../kubernetes/`](../kubernetes/) path uses upstream
`vllm/vllm-openai:v0.21.0` directly.

For plain EKS clusters without HyperPod, or HyperPod Clusters without the Inference Operator, use the [`../kubernetes/`](../kubernetes/) path.

## What's here

| File | Purpose |
|------|---------|
| `endpoint.yaml` | `InferenceEndpointConfig` CRD spec |
| `hf-token-secret.yaml.example` | Reference for HF token Secret (recommended path is `kubectl create`) |

## Prerequisites

- HyperPod EKS cluster with at least one GPU node
- HyperPod Inference Operator installed:
  - Helm chart `hyperpod-inference-operator` v2.1.1, image `v3.1`, OR
  - One-click EKS add-on (HyperPod console → Add-ons → Inference Operator)
  - Or: `sagemaker-hyperpod-cli` v3.7.1+ and `hyp install`
- The Inference Operator's prerequisite IRSA roles must be configured at install time
  (the operator does NOT need per-endpoint IAM)
- A TLS certificate output S3 bucket for endpoint certificate management
  (auto-created at install time as `sagemaker-<HP_CLUSTER>-<ID>-tls-<ID>`)
- `HF_TOKEN` with access to the model — see [parent README](../README.md#prerequisites)

## Deploy

```bash
# 1. Source environment
cd ..
cp env_vars.example env_vars
# Edit env_vars — set HF_TOKEN, INSTANCE_TYPE, etc.
source env_vars



# 2. Create the HF token Secret
kubectl create secret generic hf-token \
  --namespace=${NAMESPACE} \
  --from-literal=token=${HF_TOKEN}

# 3. Render and apply
cd hyperpod-eks/
envsubst < endpoint.yaml | kubectl apply -f -

# 4. Watch the operator drive the deployment
kubectl get inferenceendpointconfig cosmos-reason -w

# Once status reports Ready, the endpoint URL is available:
kubectl get inferenceendpointconfig cosmos-reason \
  -o jsonpath='{.status.endpointUrl}'
```

First-launch is **5-10 minutes** — image pull (~23 GB AWS DLC) + HF model download +
vLLM init. Bump `maxDeployTimeInSeconds` to `3600` if the default `1800` proves too short.

You are ready to test when the SageMaker Endpoint is successfully created. You can check this with:

```bash
aws sagemaker describe-endpoint --endpoint-name cosmos-reason --region $AWS_REGION
```

## Test

There are three ways to reach the deployed model:

### Option 1: Port-forward (simplest, works from any machine)

```bash
kubectl port-forward deploy/cosmos-reason 8000:8080 &

# Health check
curl -s http://localhost:8000/health

# Run an example
cd ../examples
python3 image_vqa.py --endpoint http://localhost:8000 --image sample.jpg --model "${MODEL_ID}" --system-prompt ""

# Batch auto-label a directory of images
python3 auto_label.py --endpoint http://localhost:8000 --image-dir ./scenes/ --model "${MODEL_ID}" --output labels.jsonl
```

### Option 2: Operator-managed ALB (in-VPC by default)

The operator provisions an ALB with TLS. By default the ALB is internal (VPC-only), but it
can be configured as internet-facing. If exposing publicly, ensure you have authentication
and access controls in place (e.g., WAF, Cognito, or mutual TLS).

```bash
ENDPOINT=$(kubectl get inferenceendpointconfig cosmos-reason \
  -o jsonpath='{.status.endpointUrl}')

# Requires VPC connectivity; -k for self-signed cert
curl -k "${ENDPOINT}/health"

cd ../examples
python3 image_vqa.py --endpoint "${ENDPOINT}" --image sample.jpg --model "${MODEL_ID}" --system-prompt ""

# Batch auto-label
python3 auto_label.py --endpoint "${ENDPOINT}" --image-dir ./scenes/ --model "${MODEL_ID}" --output labels.jsonl
```

> [!NOTE]
> If `.status.endpointUrl` is empty, the operator's cert-manager integration may not have
> completed. Verify with `kubectl get ingress -A` and `kubectl get pods -n cert-manager`.

### Option 3: SageMaker Runtime API (works from anywhere, uses IAM auth)

Invoke via the SageMaker runtime with AWS SigV4 signing — no VPC connectivity required.

```bash
echo '{"model":"'"${MODEL_ID}"'","messages":[{"role":"user","content":"What is happening in this scene? Reason about the visible cues."}],"max_tokens":64}' > /tmp/payload.json

aws sagemaker-runtime invoke-endpoint \
  --endpoint-name cosmos-reason \
  --region ${AWS_REGION} \
  --content-type application/json \
  --body fileb:///tmp/payload.json \
  /dev/stdout
```

For batch auto-labeling via the SageMaker Runtime, you would need to call `invoke-endpoint`
per image with the appropriate payload. The example scripts (`image_vqa.py`, `video_qa.py`,
`auto_label.py`) use plain HTTP requests and do not support SigV4 signing — use Option 1
or 2 with those scripts.

## Cleanup

```bash
envsubst < endpoint.yaml | kubectl delete -f -
kubectl delete secret hf-token -n ${NAMESPACE}
```

## Operational notes

- **First reference of the AWS vLLM DLC in this repo.** AWS launched a standalone vLLM
  Deep Learning Container in late 2025 (separate from DJL-LMI). Image lives at
  `763104351884.dkr.ecr.<region>.amazonaws.com/vllm:<tag>`. Tags:
  - `vllm:0.17-gpu-py312` — vLLM 0.17.0
  - `vllm:server-sagemaker-cuda-v1` — vLLM 0.19.1 (newer "server" tag with `SM_VLLM_*`
    env-var auto-translation to CLI args)
- **`maxDeployTimeInSeconds: 3600`** — default is 1800s (30 min) which is risky for
  first deploys. Vendor image pull + model download + CUDA graph compile can hit 8 min.
- **`invocationEndpoint: v1/chat/completions`** — overrides the legacy default of
  `invocations`. Required for vLLM's OpenAI-compatible API.
- **`modelInvocationPort.containerPort: 8080`** — matches the AWS DLC default port.
  The upstream `vllm/vllm-openai` image uses 8000; the AWS DLC uses 8080.
- **`tokenSecretRef`** under `huggingFaceModel` — the operator passes the secret to the
  worker pod. Secret key MUST be `token` (not `HF_TOKEN`).
- **No `JumpStartModel` path available** — Cosmos Reason is not in `SageMakerPublicHub`,
  so we use the `InferenceEndpointConfig` BYO container CRD.
- **Autoscaling** — `replicas: 1` here for simplicity. The operator has dual-layer
  autoscaling (KEDA pod-level + Karpenter node-level) configurable via `autoScaling.*`
  fields. See [operator docs](https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod-model-deployment.html).
