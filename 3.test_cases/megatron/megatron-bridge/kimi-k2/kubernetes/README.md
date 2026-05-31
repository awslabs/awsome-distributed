<!-- Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved. -->
<!-- SPDX-License-Identifier: MIT-0 -->

# Kimi K2 Full-Parameter SFT on EKS — Kubernetes Deployment

This directory contains the manifests and instructions for launching a 32-node (256-GPU)
Megatron-Bridge SFT job for Kimi K2 (1.04T-param MoE) on Amazon EKS with
UCCL-EP providing expert-parallel all-to-all over AWS EFA.

## 1. Prerequisites

Before proceeding, ensure the following are in place on the target EKS cluster
(`ml-clusters-shared-us-west-2`, account `159553542841`):

- **EFA device plugin** deployed — `vpc.amazonaws.com/efa` advertised on
  `p6-b300.48xlarge` nodes (expected 16 per node; one of the 17 NIC cards is ENA-only).
  Verify with:
  ```bash
  kubectl describe node -l node.kubernetes.io/instance-type=p6-b300.48xlarge \
    | grep -A2 "Allocatable"
  # Expected: vpc.amazonaws.com/efa: 16
  ```
- **NVIDIA device plugin** deployed — `nvidia.com/gpu: 8` per node.
- **Kubeflow Training Operator** installed (provides `PyTorchJob` CRD).
  Install guide: <https://www.kubeflow.org/docs/components/training/overview/>
- **KAI scheduler** installed — required only if you enable the OPTIONAL
  all-or-nothing (gang) scheduling (see [Section 6](#6-confirm-gang-scheduling-optional)).
- **FSx for Lustre PVC** named `fsx-claim` bound in the target namespace (see
  [Section 2](#2-fsx-for-lustre-prerequisite)).
- **Container image** built and pushed to ECR — this is the shared, model-agnostic
  env image (`megatron-bridge-uccl`) built from the **library-level** Dockerfile; see
  `3.test_cases/megatron/megatron-bridge/README.md` (`bash 1.build-and-push.sh`).
  Export `REPO_URI` before continuing.
- **Capacity-block node group** `cb-4ff6b84d` active and 32 nodes available.

## 2. FSx for Lustre Prerequisite

Kimi K2 checkpoints require approximately 4–5 TB of scratch space
(~1 TB HF weights + ~2 TB BF16 weights + ~2 TB Megatron-Core distributed checkpoint).
Provision a filesystem of at least **4800 Gi** (the next FSx Lustre Persistent-2
increment above 4.5 TB) and then create a PersistentVolume and PersistentVolumeClaim.

### 2.1 PersistentVolume

Replace `<FSX_ID>`, `<FSX_DNS>`, and `<MOUNT_NAME>` with values from the FSx console:

```yaml
# fsx-pv.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: fsx-pv
spec:
  capacity:
    storage: 4800Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteMany
  mountOptions:
    - flock
  persistentVolumeReclaimPolicy: Retain
  storageClassName: fsx-sc
  csi:
    driver: fsx.csi.aws.com
    volumeHandle: <FSX_ID>
    volumeAttributes:
      dnsname: <FSX_DNS>
      mountname: <MOUNT_NAME>
```

```bash
kubectl apply -f fsx-pv.yaml
```

### 2.2 PersistentVolumeClaim

```yaml
# fsx-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: fsx-claim
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: fsx-sc
  resources:
    requests:
      storage: 4800Gi
```

```bash
kubectl apply -f fsx-pvc.yaml
kubectl get pvc fsx-claim   # Status must be Bound before launching the job
```

## 3. Set Environment Variables

Export the following variables; they are substituted into the manifest template via
`envsubst`.

```bash
# --- Image ---
export AWS_REGION=us-west-2
export ACCOUNT=159553542841
export REGISTRY=${ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com
export IMAGE_NAME=megatron-bridge-uccl
export IMAGE_TAG=nemo-25.11.01-uccl-0dc87eb   # pin to the built image tag
export REPO_URI=${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}
# = 159553542841.dkr.ecr.us-west-2.amazonaws.com/megatron-bridge-uccl:nemo-25.11.01-uccl-0dc87eb

# --- Cluster topology (p6-b300.48xlarge, capacity-block cb-4ff6b84d) ---
export NUM_NODES=32
export GPU_PER_NODE=8
export EFA_PER_NODE=16                  # 16 EFA cards per p6-b300.48xlarge (1 card is ENA-only)
export INSTANCE_TYPE=p6-b300.48xlarge
export FSX_CLAIM=fsx-claim              # PVC bound to the FSx-for-Lustre filesystem

# --- Megatron-Bridge parallelism (256 GPUs: world = TP*PP*DP = 8*8*4 = 256) ---
export TENSOR_PARALLEL=8                # intra-node NVLink
export EXPERT_PARALLEL=32              # EP=32 spans TP*DP=32; divides 384 routed experts exactly
export PIPELINE_PARALLEL=8             # partitions ~61 transformer layers across nodes
export DATA_PARALLEL=4                  # DP = world / (TP * PP) = 256 / 64 = 4
```

The remaining inputs (FSx paths, SFT hyper-parameters such as `seq_length=4096`,
`train_iters=2000`, `global_batch_size=256`, `micro_batch_size=1`) are fixed in
`conf/kimi_k2_sft.py` / baked into the manifest env and are not exported here.

## 4. Create the SFT-config ConfigMap

The shared env image is **model-agnostic** and does **not** bake in the SFT config.
The PyTorchJob mounts `conf/kimi_k2_sft.py` at `/workspace/conf` from a ConfigMap named
`kimi-k2-sft-conf`. Create it from the conf file in the model directory (one level up
from `kubernetes/`):

```bash
cd 3.test_cases/megatron/megatron-bridge/kimi-k2

# Create (or re-create) the ConfigMap from the SFT config:
kubectl create configmap kimi-k2-sft-conf \
  --from-file=kimi_k2_sft.py=conf/kimi_k2_sft.py \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl get configmap kimi-k2-sft-conf   # confirm it exists before applying the job
```

Re-run this whenever you edit `conf/kimi_k2_sft.py` (then restart the job to pick it up).
The 21 KB config is well under the 1 MiB ConfigMap limit. The same ConfigMap is consumed by
the benchmark manifests under `benchmarks/`.

## 5. Render and Apply the Manifest

```bash
cd 3.test_cases/megatron/megatron-bridge/kimi-k2/kubernetes

envsubst < manifests/kimi-k2-sft-pytorchjob.yaml-template | kubectl apply -f -
```

This creates three objects in the current namespace:

| Object | Kind | Purpose |
|--------|------|---------|
| `etcd` | Service | rendezvous endpoint for `torchrun` |
| `etcd` | Deployment | etcd v3 server |
| `kimi-k2-sft` | PyTorchJob | 32 Worker replicas (mounts `kimi-k2-sft-conf` at `/workspace/conf`) |

## 6. Confirm Gang Scheduling (Optional)

Gang scheduling is **OPTIONAL** and is **disabled by default** in the manifest. The
`PodGroup`, the pod-template `schedulerName: kai-scheduler`, and the
`pod-group.scheduling.run.ai/name` label are all shipped **commented out**. To enable
all-or-nothing placement (recommended for capacity blocks, so reserved GPU-hours are
not burned while KAI trickles in a partial worker set), **uncomment** those blocks in
`manifests/kimi-k2-sft-pytorchjob.yaml-template` and apply the `PodGroup` in the same
namespace as the PyTorchJob.

With gang scheduling enabled, all 32 worker pods should remain `Pending` until KAI
places the full group, then transition to `Running` simultaneously:

```bash
# Watch pod phase — expect Pending -> Running transition for all 32 at once
kubectl get pods -l job-name=kimi-k2-sft -w

# Inspect the PodGroup status (KAI gang object)
# TODO(validate against image): confirm the apiVersion and group name below
# against the KAI CRD installed in the cluster.
# Reference: https://github.com/NVIDIA/KAI-Scheduler/blob/main/docs/podgroup.md
kubectl get podgroup kimi-k2-sft-pg
# Expect: status.phase = Running, status.scheduled = 32
```

Without gang scheduling, KAI may admit a subset of the 32 workers; the job then stalls
at `torchrun` rendezvous while the rest are pending. Expected pod listing once placement
succeeds (gang or not):

```
NAME                      READY   STATUS    RESTARTS   AGE
etcd-<hash>               1/1     Running   0          2m
kimi-k2-sft-worker-0      1/1     Running   0          1m
kimi-k2-sft-worker-1      1/1     Running   0          1m
...
kimi-k2-sft-worker-31     1/1     Running   0          1m
```

## 7. Watch Training Progress

```bash
# Stream logs from the rank-0 worker
kubectl logs -f kimi-k2-sft-worker-0

# Or watch all workers in parallel with stern:
stern kimi-k2-sft-worker --namespace default
```

Megatron-Bridge logs iteration progress in the format:

```
iteration        1/ 2000 | consumed samples:  256 | elapsed time per iteration (ms): ...
```

Check the `PyTorchJob` status object:

```bash
kubectl get pytorchjob kimi-k2-sft -o yaml
# status.conditions should show "Running" once workers are up
```

## 8. Confirm EFA — Not IB / NVSHMEM — Is Carrying EP Traffic

Three checks confirm the UCCL-EP / EFA path is active.

### 7.1 UCCL Shadow Module Wins Over NVIDIA DeepEP

Run a quick sanity check from inside one worker pod. `pip install` copies the
wrapper into `site-packages`, so the resolved path is **not** under `/opt/uccl`;
key on a positive UCCL marker (`deep_ep.Buffer`) instead of the path:

```bash
kubectl exec -it kimi-k2-sft-worker-0 -- python3 -c \
  "import deep_ep; print(deep_ep.__file__); \
   assert hasattr(deep_ep, 'Buffer'), 'deep_ep.Buffer missing — UCCL wrapper not active'"
```

The print shows where pip installed the wrapper (a `site-packages/deep_ep/...`
path is expected); the assert confirms the UCCL wrapper is the active module.
If `import deep_ep` resolves to an `nvidia`/`nvshmem` package or lacks `Buffer`,
the shadow install failed — verify that the container build ran
`pip install /opt/uccl/ep/deep_ep_wrapper/` correctly.

### 7.2 NCCL Selects the EFA Provider

`NCCL_DEBUG=INFO` is set in the manifest. Scan rank-0 logs for the OFI transport
selection line:

```bash
kubectl logs kimi-k2-sft-worker-0 | grep -i "NET/OFI\|provider\|efa"
```

Expected output (exact text varies by aws-ofi-nccl version; see the
`# TODO` below):

```
NCCL INFO NET/OFI selected transport EFA
```

<!-- TODO(validate against image): capture the exact NCCL_DEBUG=INFO provider
selection line from a live run and paste it here. The line format is printed by
aws-ofi-nccl and depends on the installed version bundled in the EFA installer
1.48.0 + the aws-ofi-nccl shipped by the NGC base. -->

### 7.3 No NVSHMEM / IB Initialization

Confirm absence of InfiniBand or NVSHMEM init messages in the logs:

```bash
kubectl logs kimi-k2-sft-worker-0 | grep -i "nvshmem\|ibverbs\|mlx5\|hpcx"
# Should return no output — IB libraries were removed in the Dockerfile.
```

### 7.4 UCCL-EP Bandwidth Logging (Optional)

UCCL-EP logs all-to-all transfer stats when `PER_EXPERT_BATCHING=1` is set
(included in the manifest env). Look for lines similar to:

```bash
kubectl logs kimi-k2-sft-worker-0 | grep -i "uccl\|deep_ep\|efa.*bw\|all2all"
```

<!-- TODO(validate against image): capture the actual UCCL-EP all-to-all log
prefix from a live run — the exact format is implementation-defined. -->

## 9. Teardown

```bash
# Delete the training job (also removes worker pods)
envsubst < manifests/kimi-k2-sft-pytorchjob.yaml-template | kubectl delete -f -

# Verify pods are gone
kubectl get pods -l job-name=kimi-k2-sft

# The FSx PV/PVC are retained by default (Retain policy).
# Delete only if no longer needed:
kubectl delete pvc fsx-claim
kubectl delete pv fsx-pv
```
