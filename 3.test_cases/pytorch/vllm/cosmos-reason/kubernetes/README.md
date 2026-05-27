# Cosmos Reason on Vanilla EKS

Plain Kubernetes `Deployment` + `Service` for any EKS cluster with GPU nodes.
Uses the upstream `vllm/vllm-openai` container image directly.

If you have HyperPod EKS and want managed scale-to-zero, KV cache, and intelligent
routing, use the [`../hyperpod-eks/`](../hyperpod-eks/) path instead.

## What's here

| File | Purpose |
|------|---------|
| `deployment.yaml` | `Deployment` (pod spec) + `Service` (ClusterIP) |
| `hf-token-secret.yaml.example` | Reference manifest — recommended path is `kubectl create secret` rather than apply (so the token never lands in version control) |

## Prerequisites

- EKS cluster with at least one GPU node
- NVIDIA device plugin DaemonSet installed (Karpenter usually handles this)
- `kubectl` configured with cluster context
- `envsubst` (provided by `gettext`)
- `HF_TOKEN` with access to the model — see [parent README](../README.md#prerequisites)

## Deploy

```bash
# 1. Source environment
cd ..
cp env_vars.example env_vars
# Edit env_vars — set HF_TOKEN at minimum
source env_vars

# 2. Create the HF token Secret
kubectl create secret generic hf-token \
  --namespace=${NAMESPACE} \
  --from-literal=token=${HF_TOKEN}

# 3. Render and apply the manifests
cd kubernetes/
envsubst < deployment.yaml | kubectl apply -f -

# 4. Wait for the Pod to become Ready
kubectl wait --for=condition=Ready pod \
  -l app=cosmos-reason \
  --namespace=${NAMESPACE} \
  --timeout=10m

# 5. Verify
kubectl logs -l app=cosmos-reason --tail=20
```

First-launch is **3-8 minutes** (image pull + HF model download + vLLM init).

## Test

```bash
# Port-forward to localhost
kubectl port-forward -n ${NAMESPACE} svc/cosmos-reason 8000:8000 &

# Hit /health
curl -s http://localhost:8000/health

# List the loaded model
curl -s http://localhost:8000/v1/models | jq

# Try an example
# This asks the model "What is in this image, and what is happening? Reason about visible cues."
cd ../examples
python3 image_vqa.py --image sample.jpg --model ${MODEL_ID}
```

You can also customize the question:
```bash
python3 image_vqa.py --image sample.jpg --prompt "How many vehicles are visible and what types are they?"
```

Test with auto labeling use case:
```bash
python3 auto_label.py --image-dir ./scenes/ --output labels.jsonl --limit 5
```

## Cleanup

```bash
envsubst < deployment.yaml | kubectl delete -f -
kubectl delete secret hf-token -n ${NAMESPACE}
```

## Notes

- The `Service` is `ClusterIP`. To expose externally, add an `Ingress` (ALB recommended)
  or change to `LoadBalancer`.
- **Autoscaling:** No HPA is included by default. Inference is GPU-bound and CPU-based
  scaling is not a useful proxy for queue depth. For production, configure
  [KEDA](https://keda.sh/) on the vLLM Prometheus metric `vllm:num_requests_running`,
  or pair with Karpenter for node-level scale-out.
- `/dev/shm` is mounted via `emptyDir { medium: Memory }` (per the
  [`awsome-distributed-ai`](https://github.com/awslabs/awsome-distributed-ai) review
  conventions — never `hostPath: /dev/shm`).
