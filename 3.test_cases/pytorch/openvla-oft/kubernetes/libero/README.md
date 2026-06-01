<!-- Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved. -->
<!-- SPDX-License-Identifier: MIT-0 -->

# Fine-tune OpenVLA-OFT on LIBERO on Amazon EKS

This walkthrough packages the opinionated LIBERO fine-tuning recipe from upstream
[LIBERO.md](https://github.com/moojink/openvla-oft/blob/main/LIBERO.md) as a set
of reusable Kubernetes manifests that run on Amazon EKS or SageMaker
HyperPod-on-EKS. The Training Job passes the upstream hyperparameters to
`/openvla-oft/finetune.py` **verbatim** — batch size, learning rate, schedule,
LoRA rank, `run_id_note`, and the LIBERO-specific input/proprio/image flags.
Nothing is re-tuned here.

If you want the top-level test-case overview (Dockerfile rationale,
references), see [`../../README.md`](../../README.md).

The recipe has three moving parts:

1. A shared `PersistentVolumeClaim` (the **Dataset PVC**) mounted at `/data`
   that holds the RLDS dataset, the Hugging Face cache, and the training
   checkpoints.
2. A one-shot `batch/v1` **Download Job** that stages
   `openvla/modified_libero_rlds` TFDS shards onto the Dataset PVC using
   `huggingface-cli`.
3. A Kubeflow `PyTorchJob` (**Training Job**) that invokes
   `/openvla-oft/finetune.py` with the upstream LIBERO flags, reads shards
   from the PVC, and writes checkpoints to `/data/runs/<run_id>`.

Credentials (`HF_TOKEN`, `WANDB_API_KEY`) flow through a single Kubernetes
`Secret` named `openvla-oft-secrets`, referenced via `secretKeyRef` so tokens
never land in rendered YAML.

## 0. Prerequisites

### 0.1. EKS or HyperPod-on-EKS cluster

You need an EKS cluster (or a SageMaker HyperPod-on-EKS cluster) with a GPU
node pool. Cluster creation instructions live in
[`1.architectures`](../../../../../1.architectures), the
[aws-do-eks](https://bit.ly/do-eks) project, or the
[eks-blueprints](https://github.com/aws-ia/terraform-aws-eks-blueprints)
project.

Point your local kubeconfig at the cluster:

```bash
aws eks update-kubeconfig --name <EKS_CLUSTER_NAME>
kubectl config current-context
```

### 0.2. Kubeflow Training Operator

The Training Job is a `kubeflow.org/v1` `PyTorchJob`, so the Kubeflow Training
Operator must be installed in the cluster:

```bash
kubectl apply -k "github.com/kubeflow/training-operator/manifests/overlays/standalone?ref=v1.9.1"
```

### 0.3. FSx for Lustre CSI driver

Both storage paths below (dynamic and static) use the `fsx.csi.aws.com`
provisioner. Install the driver via the managed EKS add-on or per the upstream
[aws-fsx-csi-driver](https://github.com/kubernetes-sigs/aws-fsx-csi-driver)
instructions. Minimum tested version: **`v1.0.0`** (the version shipped by the
current `aws-fsx-csi-driver` EKS add-on).

### 0.4. Local tooling: `envsubst` (`$$`-aware) and `kubectl`

The manifests in this directory embed bash scripts inside YAML and rely on
`$$` as an escape so envsubst leaves bash-intended variables literal, and
`libero-finetune.yaml` additionally uses `${VAR:-default}` default-value
expansion (for `${RUN_ID_NOTE:-…}`). GNU gettext's `envsubst` (the one shipped
on macOS via `gettext` and on Linux via `gettext` / `gettext-base`) supports
**neither**: it has no `$$` escape, so it mangles the inline bash, and it does
not understand `${VAR:-default}`, so it leaves that token literal in the
rendered YAML. Install [a8m/envsubst](https://github.com/a8m/envsubst), which
honours both. It is the recommended tool, and the one these manifests render
cleanly with out of the box.

There is no Homebrew formula. Install from the upstream prebuilt release
binary (recommended) or `go install`:

```bash
# macOS / Linux (prebuilt binary). `uname -s` and `uname -m` pick the right
# asset: macOS Apple Silicon → envsubst-Darwin-arm64, macOS Intel →
# envsubst-Darwin-x86_64, Linux x86_64 → envsubst-Linux-x86_64, Linux arm64
# → envsubst-Linux-arm64.
curl -L "https://github.com/a8m/envsubst/releases/download/v1.4.3/envsubst-$(uname -s)-$(uname -m)" \
  -o /usr/local/bin/envsubst
chmod +x /usr/local/bin/envsubst

# Or, if you have Go installed:
go install github.com/a8m/envsubst/cmd/envsubst@latest
# Then make sure $(go env GOPATH)/bin is on your PATH.
```

On Apple Silicon, `/usr/local/bin` is not on PATH by default — Homebrew's
binaries live under `/opt/homebrew/bin`, which has higher priority. Either
drop the binary into `/opt/homebrew/bin/envsubst` instead, or add
`/usr/local/bin` to PATH ahead of `/opt/homebrew/bin`.

Verify the binary on your PATH is the `$$`-aware one:

```bash
envsubst --version
# expect: "envsubst version: vX.Y.Z" — that's a8m/envsubst.
# If you see "envsubst (GNU gettext-runtime)" instead, the GNU binary is
# still winning the PATH race. Re-check `which envsubst` and `echo $PATH`.
```

If you cannot install a8m/envsubst and must fall back to GNU gettext's
`envsubst`, the allow-list form alone is **not** enough. An allow-list only
restricts *which* names GNU substitutes — it does not teach GNU the `$$`
escape or `${VAR:-default}` expansion that these manifests rely on. To render
with GNU envsubst you must also edit the manifests so they no longer depend on
those two a8m features:

1. **Collapse every `$$NAME` to `$NAME`.** GNU has no `$$` escape, so the
   doubled form would render as a literal `$` followed by the substituted (or
   stripped) value, corrupting the inline bash in `libero-download.yaml`.
   Rewrite each `$$NAME` / `$${NAME[@]}` in the container `args` body to the
   single-dollar `$NAME` / `${NAME[@]}` form, then rely on the allow-list to
   keep GNU from touching those runtime variables.
2. **Expand `${VAR:-default}` by hand.** GNU leaves `${RUN_ID_NOTE:-…}` in
   `libero-finetune.yaml` literal. Replace it with the resolved value (the
   upstream `run_id_note` string, or your override) before rendering.

Then render with an explicit allow-list naming **only** the manifest-level
placeholders for that file, so every remaining `$NAME` (now your runtime bash
variables) is left literal. The allow-list differs per manifest:

```bash
# libero-download.yaml — TASK_SUITE is consumed at render time (env: block)
# AND at runtime (inline bash); after step 1 both are single-dollar, so it
# must be in the allow-list.
envsubst '$IMAGE_URI $DATA_PVC_NAME $NAMESPACE $TASK_SUITE $TASK_SUITE_DNS' \
  < libero-download.yaml | kubectl apply -f -

# libero-finetune.yaml — after expanding ${RUN_ID_NOTE:-…} by hand (step 2).
envsubst '$IMAGE_URI $DATA_PVC_NAME $NAMESPACE $INSTANCE_TYPE $NUM_NODES $GPU_PER_NODE $EFA_PER_NODE $FI_PROVIDER $TASK_SUITE $TASK_SUITE_DNS $WANDB_MODE $WANDB_ENTITY $WANDB_PROJECT' \
  < libero-finetune.yaml | kubectl apply -f -

# pvc-fsx-lustre-dynamic.yaml — no $$ or ${VAR:-default}, so no edits needed.
envsubst '$DATA_PVC_NAME $DATA_PVC_SIZE $FSX_SUBNET_ID $FSX_SECURITY_GROUP_ID' \
  < pvc-fsx-lustre-dynamic.yaml | kubectl apply -f -

# pv-fsx-lustre-static.yaml — no $$ or ${VAR:-default}, so no edits needed.
envsubst '$DATA_PVC_NAME $DATA_PVC_SIZE $FSX_FILESYSTEM_ID $FSX_DNS_NAME $FSX_MOUNT_NAME' \
  < pv-fsx-lustre-static.yaml | kubectl apply -f -
```

Because the GNU path requires hand-editing two of the manifests on every
render, installing a8m/envsubst is strongly preferred.

`kubectl` must also be installed and configured for the target cluster.

### 0.5. Container image

The recipe builds the `openvla-oft` image from the test case's
`Dockerfile` (one directory up) and tags it with the upstream commit the
Dockerfile pins (`OPENVLA_OFT_COMMIT`), not `latest`. Fixed tags are the
repo convention and they keep a rebuild from silently serving a stale image
— the exact `:latest` trap the `ncclDevCommDestroy` troubleshooting entry
below calls out. The build instructions are self-contained and can be run
from this directory without changing into the parent path.

The Dockerfile builds against the AWS Deep Learning Container (DLC)
PyTorch training image so that PyTorch, NCCL, EFA, libfabric, and the
`aws-ofi-nccl` plugin are all version-pinned together by AWS. That
avoids the `undefined symbol: ncclDevCommDestroy` ABI mismatch you can
hit when stacking PyPI `torch` wheels on top of the `nccl-tests` base.

The build also uses `docker buildx build --platform linux/amd64 --load`
because every AWS GPU instance this recipe targets is x86_64. A plain
`docker build` on Apple Silicon (or any arm64 host) produces an arm64
manifest and the kubelet rejects the pull with
`no match for platform in manifest: not found`. The push remains a
separate `docker image push` step.

Authentication note: the build pulls from the AWS DLC ECR registry under
account `763104351884`, which is separate from your own ECR account. The
quick reference below logs in to both registries — the DLC one for the
pull during build, and yours for the push after.

Quick reference (run from the test-case root
`3.test_cases/pytorch/openvla-oft`, the directory that holds the
`Dockerfile`, so `-f Dockerfile` and a `.` build context are the current
path):

```bash
# From the repo root, cd into the test case directory so the Dockerfile
# and build context are the current path.
cd 3.test_cases/pytorch/openvla-oft

# One-time setup on a fresh host: create a buildx builder that supports
# cross-platform builds and register QEMU emulation. Skip if you already
# have a buildx builder (`docker buildx ls`).
docker buildx create --use --name openvla-builder
docker run --privileged --rm tonistiigi/binfmt --install all

# AWS_REGION defaults to your AWS CLI's configured region. Override if
# your cluster lives in a different region than your CLI default.
export AWS_REGION=${AWS_REGION:-$(aws configure get region)}
export REGISTRY=$(aws sts get-caller-identity --query Account --output text).dkr.ecr.${AWS_REGION}.amazonaws.com/

# Tag the image with the upstream commit the Dockerfile pins
# (OPENVLA_OFT_COMMIT). Bump this in lockstep when you bump the Dockerfile.
# It must match the tag in IMAGE_URI in env_vars.
export IMAGE_TAG=e4287e9

# Log in to the DLC registry (account 763104351884) so buildx can pull
# the base image during the build.
aws ecr get-login-password --region ${AWS_REGION} \
  | docker login --username AWS --password-stdin \
      763104351884.dkr.ecr.${AWS_REGION}.amazonaws.com

# Build for linux/amd64 with the DLC pulled from your region.
docker buildx build --platform linux/amd64 \
  --build-arg AWS_REGION=${AWS_REGION} \
  --load \
  -f Dockerfile \
  -t ${REGISTRY}openvla-oft:${IMAGE_TAG} \
  .

# Push to your own ECR.
aws ecr get-login-password --region ${AWS_REGION} \
  | docker login --username AWS --password-stdin ${REGISTRY}
docker image push ${REGISTRY}openvla-oft:${IMAGE_TAG}
```

### 0.6. Clone this repository

```bash
git clone https://github.com/awslabs/awsome-distributed-ai/
cd awsome-distributed-ai/3.test_cases/pytorch/openvla-oft/kubernetes/libero
```

### 0.7. Configure environment variables

The committed template is `env_vars.example`. Copy it once to `env_vars`,
which is gitignored (matched by the repo's top-level `**/env_vars` rule), and
edit your local copy:

```bash
cp env_vars.example env_vars
"${EDITOR:-vi}" env_vars
```

Every later step in this walkthrough that says `source env_vars` reads from
this local copy. Re-edit and re-source it whenever you change a variable
(for example, switching `WANDB_MODE` or `TASK_SUITE`).

## 1. Instance sizing

Upstream LIBERO.md documents a per-GPU VRAM footprint of **approximately
62 GiB** at the recipe's default `batch_size=8`. The minimum viable GPU class
for the default recipe is therefore **A100 80 GiB or H100 80 GiB** (so
`p4de.24xlarge`, `p5.48xlarge`, or equivalent HyperPod node classes).

GPUs with less than 80 GiB of VRAM (A10G, L4, A100 40 GiB, etc.) are **not
covered** by this recipe at the default settings.

If you need to fit onto smaller GPUs, change two flags together so that the
effective batch size stays the same (upstream LIBERO.md guidance):

- Lower `--batch_size` (for example, from `8` to `4` or `2`).
- Raise `--grad_accumulation_steps` proportionally (from `1` to `2` or `4`).

Both flags live in `libero-finetune.yaml`. Edit the manifest before running
`envsubst`, or override the values at render time. Results will no longer be
bit-for-bit comparable to the upstream numbers, but the training dynamics stay
close.

## 2. PVC provisioning

The Dataset PVC is the only integration point between the Download Job and
the Training Job. Pick one of the three paths below based on your cluster.

Recommended capacity: **at least 100 GiB**. The Dataset PVC holds three
things that share the volume:

- **RLDS dataset** — roughly 2.5 GiB per LIBERO suite (≈10.2 GiB for all
  four suites).
- **Hugging Face cache** (`/data/hf-cache`) — the base `openvla/openvla-7b`
  snapshot the run downloads, ~15 GiB in bf16.
- **Checkpoints** (`/data/runs/<run_id>`) — see "Checkpoint location" below.

The smoke test ships `--save_latest_checkpoint_only=True`, so it keeps a
single, repeatedly overwritten checkpoint dir. Because
`--merge_lora_during_training=True` writes the full merged OpenVLA-7B
(~15 GiB) and not just the small rank-32 LoRA adapter, that one dir is
~15 GiB. Total steady-state footprint is therefore ~30–40 GiB, comfortably
inside the 100 GiB minimum.

> **Heads-up if you change the save flags.** Setting
> `--save_latest_checkpoint_only=False` keeps *every* checkpoint, and with
> the merge enabled each one is a full ~15 GiB merged 7B model. At
> `--save_freq=10` over `--max_steps=100` that is ten dirs (~150 GiB) and
> blows past the 100 GiB minimum. If you need all checkpoints, either drop
> `--merge_lora_during_training` (keep only the small adapters) or provision
> a much larger PVC. The `env_vars.example` template provisions `1200Gi` to
> give a realistic margin on a fresh FSx filesystem.

### Checkpoint location

Checkpoints are written to `/data/runs/<run_id>` on the Dataset PVC by
default, so they share the PVC with the RLDS shards and the Hugging Face
cache. This is intentional: a single PVC is simpler to reason about and to
tear down.

If you need to route checkpoints somewhere else (for example, a second PVC
backed by a different FSx filesystem), override `--run_root_dir` via the
`RUN_ID_NOTE` sibling pattern: edit `libero-finetune.yaml` so
`--run_root_dir` references an env-var-driven path, add the corresponding
`volumeMount`, and set that env var in `env_vars` before you render.

### 2.1. EKS with dynamic provisioning

Use this path on plain EKS clusters, where the FSx for Lustre CSI driver
provisions a fresh filesystem on demand. Minimum FSx CSI driver version:
**`v1.0.0`**.

Required env vars (in addition to the defaults in `env_vars.example`):

- `FSX_SUBNET_ID` — a private subnet ID in the same VPC as your node pool.
- `FSX_SECURITY_GROUP_ID` — a security group that allows Lustre traffic
  (ports 988, 1018–1023).

Render and apply:

```bash
source env_vars
envsubst < pvc-fsx-lustre-dynamic.yaml | kubectl apply -f -
```

The PVC will stay in `Pending` until the CSI driver finishes provisioning the
filesystem (a few minutes). Check with:

```bash
kubectl get pvc "${DATA_PVC_NAME}"
```

If your cluster already has a cluster-wide FSx `StorageClass`, skip the
`StorageClass` document in this file and point the `PersistentVolumeClaim`
at the existing class instead.

### 2.2. HyperPod-on-EKS with a pre-provisioned FSx filesystem

Use this path on SageMaker HyperPod-on-EKS (or any cluster that already has
an FSx for Lustre filesystem provisioned out-of-band via CloudFormation,
Terraform, or the console). The filesystem lifecycle is owned outside
Kubernetes, so the PV uses `persistentVolumeReclaimPolicy: Retain` and
`storageClassName: ""` to disable dynamic provisioning.

Required env vars:

- `FSX_FILESYSTEM_ID` — for example, `fs-0abc123def456`.
- `FSX_DNS_NAME` — for example, `fs-0abc123def456.fsx.us-east-1.amazonaws.com`.
- `FSX_MOUNT_NAME` — the FSx mount name, from the FSx console or:

  ```bash
  aws fsx describe-file-systems \
    --query 'FileSystems[*].{Id:FileSystemId,DNS:DNSName,Mount:LustreConfiguration.MountName}'
  ```

Render and apply:

```bash
source env_vars
envsubst < pv-fsx-lustre-static.yaml | kubectl apply -f -
```

Verify the PVC binds to the static PV:

```bash
kubectl get pv  fsx-pv-openvla-oft-libero
kubectl get pvc "${DATA_PVC_NAME}"
```

### 2.3. Existing PVC bound by the cluster (no manifest to apply)

Use this path when the cluster was created with an FSx for Lustre filesystem
already exposed as a `PersistentVolumeClaim` — for example, the `fsx-claim`
PVC that ships with the SageMaker HyperPod-on-EKS / `aws-do-eks` cluster
templates. In that case the FSx CSI driver, `StorageClass`, `PersistentVolume`,
and `PersistentVolumeClaim` are all already in place, and rendering either of
the two manifests above would only create a duplicate (and likely conflicting)
binding.

No FSx env vars are required. Leave `FSX_FILESYSTEM_ID`, `FSX_SUBNET_ID`,
`FSX_SECURITY_GROUP_ID`, `FSX_DNS_NAME`, and `FSX_MOUNT_NAME` empty.

`env_vars.example` already defaults `DATA_PVC_NAME=fsx-claim`, so on a
cluster provisioned from those templates you do not need to override
`DATA_PVC_NAME` at all. Confirm the PVC exists and is healthy:

```bash
kubectl get pvc
# NAME        STATUS   VOLUME      CAPACITY   ACCESS MODES   STORAGECLASS  AGE
# fsx-claim   Bound    fsx-pv...   1.2Ti      RWX            fsx-sc        3d
```

If your cluster exposes the filesystem under a different PVC name, override
the default before sourcing `env_vars`:

```bash
export DATA_PVC_NAME=<your-pvc-name>
```

The PVC must report `STATUS: Bound` and `ACCESS MODES: RWX` (`ReadWriteMany`)
so multiple worker pods can mount it concurrently. Then jump straight to
section 3 and skip both `pvc-fsx-lustre-dynamic.yaml` and
`pv-fsx-lustre-static.yaml` — the Download Job and Training Job only depend on
`DATA_PVC_NAME` and the `/data` directory tree.

## 3. Create the `openvla-oft-secrets` Kubernetes Secret

Both Jobs read `HF_TOKEN` and `WANDB_API_KEY` from a single `openvla-oft-secrets`
Secret via `secretKeyRef`. Create it once per namespace. Export both values in
your local shell first (leave either empty to create an empty key — the pod
still starts because `optional: true` is set on each key):

```bash
export HF_TOKEN=<your-hugging-face-token-or-empty>
export WANDB_API_KEY=<your-wandb-api-key-or-empty>

kubectl create secret generic openvla-oft-secrets \
  --from-literal=HF_TOKEN="${HF_TOKEN:-}" \
  --from-literal=WANDB_API_KEY="${WANDB_API_KEY:-}"
```

Verify:

```bash
kubectl get secret openvla-oft-secrets
```

If you rotate a token, delete and recreate the Secret. The Jobs re-read the
Secret on pod startup, so no manifest changes are needed.

## 4. Submit the Download Job

The Download Job stages `openvla/modified_libero_rlds` TFDS shards onto the
Dataset PVC. It runs on CPU-only nodes (no `nvidia.com/gpu` request), so it
can be scheduled anywhere in the cluster.

Set `TASK_SUITE` to one of the four LIBERO suites, or to `all` to download
every suite in a single run. Derive the DNS-safe form at the same time — the
manifest uses it in `metadata.name`:

```bash
export TASK_SUITE=libero_spatial_no_noops
export TASK_SUITE_DNS="${TASK_SUITE//_/-}"
source env_vars
envsubst < libero-download.yaml | kubectl apply -f -
```

`TASK_SUITE` is re-validated inside the pod against the allow-list
(`libero_spatial_no_noops`, `libero_object_no_noops`, `libero_goal_no_noops`,
`libero_10_no_noops`, `all`). Any other value exits the pod with status 2 and
logs the allow-list on stderr.

Wait for the Job to reach `Succeeded`:

```bash
kubectl wait --for=condition=complete \
  "job/openvla-oft-libero-download-${TASK_SUITE_DNS}" --timeout=60m
kubectl logs -l "app=openvla-oft-libero-download" --tail=50
```

The Download Job is idempotent: re-running it against a PVC that already
contains a complete copy of the requested suite is a no-op in practice,
because `huggingface-cli` content-addressed caching detects matching bytes.

### Optional: migrate `pip install hf_transfer` to an `initContainer`

The current `libero-download.yaml` installs `hf_transfer` inline as the first
step of the container command. This keeps the base image lean and the manifest
short, but it re-runs `pip install` on every retry.

If cold-start time or repeated `pip install` activity becomes a concern, move
the install into an `initContainer` and keep the main container free of
`pip install`. The structural change looks like this (schematic — drop into
`spec.template.spec` next to the existing `containers:` block):

```yaml
initContainers:
  - name: install-hf-transfer
    image: ${IMAGE_URI}
    command: ["/bin/bash", "-lc"]
    args:
      - |
        set -euo pipefail
        pip install --no-cache-dir --target=/hf-tools 'hf_transfer>=0.1.6'
    volumeMounts:
      - name: hf-tools
        mountPath: /hf-tools
volumes:
  - name: hf-tools
    emptyDir: {}
```

Then add the matching `volumeMount` on the main `download` container, prepend
`/hf-tools` to `PYTHONPATH`, and drop the `pip install` line from the args
block. Both approaches satisfy the recipe's design — this walkthrough uses
the inline form by default for simplicity.

## 5. Verify the TFDS layout

Before spending GPU hours, confirm the RLDS tree on the PVC is well-formed.
`verify-tfds-layout.sh` checks that `/data/datasets/rlds/<suite>/` contains
a `dataset_info.json` file and at least one `*.tfrecord-*` shard. It exits
`0` on success and `1` on any missing-path failure.

Run it against a pod that mounts the PVC. The most reliable option after
the Download Job has completed (and its pod has been garbage-collected) is
to spin up a one-off pod that mounts the same PVC at `/data` and pipes the
script in via stdin.

We use `busybox:1.37` because the script needs `find` and `grep`. The
minimal `amazonlinux:2023` image does not ship `findutils` and the script
fails with `find: command not found` followed by a misleading
`FAIL: no dataset_info.json …` line. Busybox bundles `find` and `grep` in
the base image, so the verify finishes in seconds with no extra installs.

Quick one-shot:

```bash
kubectl delete pod libero-verify --ignore-not-found

kubectl run libero-verify --restart=Never \
  --image=busybox:1.37 \
  --overrides='{
    "spec": {
      "restartPolicy": "Never",
      "containers": [{
        "name": "libero-verify",
        "image": "busybox:1.37",
        "stdin": true,
        "stdinOnce": true,
        "command": ["sh", "-s", "libero_spatial_no_noops"],
        "volumeMounts": [{"name": "data", "mountPath": "/data"}]
      }],
      "volumes": [{
        "name": "data",
        "persistentVolumeClaim": {"claimName": "'"${DATA_PVC_NAME}"'"}
      }]
    }
  }' \
  --attach=true --stdin=true --rm=false \
  < verify-tfds-layout.sh

# Read the verdict and clean up.
kubectl logs libero-verify
kubectl delete pod libero-verify
```

Swap `libero_spatial_no_noops` for `all` to verify all four suites at once.
The script exits `0` on success with a line like
`OK: /data/datasets/rlds/libero_spatial_no_noops looks like a well-formed
TFDS tree`. A `FAIL:` line means the download did not finish — re-run the
Download Job and let it complete before re-checking.

A few notes on why the recipe is shaped that way:

- `command: ["sh", "-s", "libero_spatial_no_noops"]` makes busybox `ash`
  read the script body from stdin and treat the suite name as `$1`. The
  script's `[[ … ]]`, `for … in …`, and `find`/`grep` syntax are all
  busybox-compatible.
- `stdin: true` + `stdinOnce: true` keep the container's stdin open just
  long enough to receive the redirected file, then close it so `ash` sees
  EOF and exits. Without `stdinOnce`, the container hangs waiting for an
  interactive session.
- `--attach=true --stdin=true --rm=false` is the kubectl side of the same
  contract: connect your local stdin (the redirected file) to the
  container, then leave the pod around so `kubectl logs` can read its
  output afterwards.
- Drop `-it` (the interactive/TTY flags). Piping a file in conflicts with
  TTY allocation and triggers
  `Unable to use a TTY - input is not a terminal …` plus an attach race.

If you'd rather poke around interactively (run `find`, `du`, etc.), apply
a sleep pod and `kubectl exec` into it:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: libero-shell
spec:
  restartPolicy: Never
  containers:
    - name: shell
      image: busybox:1.37
      command: ["sleep", "3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: ${DATA_PVC_NAME}
EOF

kubectl wait --for=condition=Ready pod/libero-shell --timeout=120s

# Run the verify script from your local checkout.
kubectl exec -i libero-shell -- sh -s libero_spatial_no_noops \
  < verify-tfds-layout.sh

# Or drop into a shell to inspect manually.
kubectl exec -it libero-shell -- sh
# then, inside the pod:
#   ls -la /data/datasets/rlds/
#   find /data/datasets/rlds/libero_spatial_no_noops -maxdepth 3
#   du -sh /data/datasets/rlds/*

# Clean up when done.
kubectl delete pod libero-shell
```

If the Download Job pod is still around (Jobs do not delete completed
pods automatically), you can also `kubectl exec` directly into it instead
of starting a fresh pod. That pod has bash + findutils baked in:

```bash
kubectl exec -it \
  $(kubectl get pod -l app=openvla-oft-libero-download -o name | head -n1) \
  -- bash -s libero_spatial_no_noops < verify-tfds-layout.sh
```

The script reads `$LIBERO_DATA_ROOT` (default `/data/datasets/rlds`) if
your PVC mounts the dataset under a different path.

### Choosing a Weights & Biases mode

The Training Job reads `WANDB_API_KEY` from `openvla-oft-secrets` via
`secretKeyRef` with `optional: true`, and reads `WANDB_MODE` as a plain env
var rendered from `env_vars`. Three modes are supported:

| `WANDB_MODE` | Network calls | Local files                            | `WANDB_API_KEY` required | When to use                                                                |
|--------------|---------------|----------------------------------------|--------------------------|----------------------------------------------------------------------------|
| `disabled`   | None          | None                                   | No                       | Default. Cluster has no outbound `wandb.ai` access, or you simply do not want telemetry. All `wandb` calls are no-ops. |
| `offline`    | None          | `/data/runs/<run_id>/wandb/` on the PVC | No                       | You want a local run record you can later `wandb sync` to wandb.ai from a workstation, but you do not want the pod to make outbound calls. |
| `online`     | Streams to `wandb.ai` | `/data/runs/<run_id>/wandb/` on the PVC | Yes                      | You have a wandb account, the cluster has outbound `wandb.ai` access, and you want live dashboards.                |

The recipe's `env_vars` defaults `WANDB_MODE=disabled` so the Training Job
runs to completion without telemetry and without needing a `WANDB_API_KEY` in
the Secret. Override the variable in your shell before sourcing `env_vars`:

```bash
# Default — telemetry off, no local files. WANDB_API_KEY can be empty.
source env_vars

# Local files only, never contacts wandb.ai. WANDB_API_KEY can be empty.
export WANDB_MODE=offline
source env_vars

# Live streaming to wandb.ai. Requires WANDB_API_KEY in openvla-oft-secrets.
export WANDB_MODE=online
source env_vars
```

If `WANDB_MODE=online` and `WANDB_API_KEY` is empty in the Secret, the
`wandb` client falls back to its own anonymous-or-fail behaviour at runtime;
that is out of scope for this recipe. To run online cleanly, recreate the
Secret with a real key per the section 3 instructions.

## 6. Submit the Training Job

The Training Job is a Kubeflow `PyTorchJob` that invokes
`/openvla-oft/finetune.py` with the upstream LIBERO hyperparameters verbatim.
The full flag set lives in the `command:` block of `libero-finetune.yaml` and
matches the recipe documented in
[LIBERO.md](https://github.com/moojink/openvla-oft/blob/main/LIBERO.md): the
Training Job passes those flags verbatim — batch size, learning rate, schedule,
LoRA rank, `run_id_note`, input/proprio/image flags.

Set `TASK_SUITE` (and `TASK_SUITE_DNS`) to match the suite you downloaded,
source `env_vars`, then render and apply:

```bash
export TASK_SUITE=libero_spatial_no_noops
export TASK_SUITE_DNS="${TASK_SUITE//_/-}"
source env_vars
envsubst < libero-finetune.yaml | kubectl apply -f -
```

Sourcing `env_vars` with an unset or empty `TASK_SUITE` fails loudly at
`source` time (`:?` parameter expansion) with the allow-list in the error
message, so you cannot accidentally submit a Training Job for the wrong
suite.

## 7. Monitor the Training Job

Use `kubectl get pytorchjob` to watch the job transition states, and tail the
worker-0 log for the live training output:

```bash
kubectl get pytorchjob
kubectl get pods -l app=openvla-oft-libero-finetune
```

```log
NAME                                  STATE     AGE
openvla-oft-libero-libero-spatial-no-noops   Running   4m12s
```

Tail the first worker's log (worker-0 is the `torchrun` master, so it carries
the progress output):

```bash
kubectl logs -f "openvla-oft-libero-${TASK_SUITE_DNS}-worker-0"
```

### W&B mode

Telemetry behaviour is set by `WANDB_MODE`, defaulting to `disabled`. See
[Choosing a Weights & Biases mode](#choosing-a-weights--biases-mode) above
for the three supported modes (`disabled`, `offline`, `online`) and when
to use each.

## 8. Stop the Training Job

```bash
envsubst < libero-finetune.yaml | kubectl delete -f -
```

If you wish to launch a new Training Job for the same suite you must first
stop the previous one, even if it is in `Completed` state (Kubeflow will
reject duplicate `metadata.name` submissions).

## 9. Troubleshooting

### Worker-0 fails with `undefined symbol: ncclDevCommDestroy`

**Symptom.** The Training Job pod schedules and starts but worker-0 exits
within a few seconds. `kubectl logs openvla-oft-libero-${TASK_SUITE_DNS}-worker-0`
shows:

```log
Traceback (most recent call last):
  File "/usr/local/bin/torchrun", line 3, in <module>
    from torch.distributed.run import main
  ...
ImportError: /usr/local/lib/python<py>/dist-packages/torch/lib/libtorch_cuda.so:
  undefined symbol: ncclDevCommDestroy
```

**Cause.** A PyTorch wheel installed during `docker build` was compiled
against an NCCL ABI newer than the `libnccl.so` shipped with the base
image. `ncclDevCommDestroy` is the symbol PyTorch's `libtorch_cuda.so`
calls; it landed in NCCL 2.20+. If the base image's NCCL is older, the
runtime link fails before any user code runs. This is the canonical
symptom of stacking a PyPI `torch` wheel on top of
`public.ecr.aws/hpc-cloud/nccl-tests`, which pins its own NCCL build for
the benchmark binaries it ships.

**Fix.** Rebuild the image against the AWS Deep Learning Container (DLC)
PyTorch base, which version-pins PyTorch + NCCL + EFA + libfabric +
`aws-ofi-nccl` together. The current `Dockerfile` already does this and
includes a `python -c "import torch"` sanity check at build time so the
mismatch fails the build instead of pod startup. If you have a stale
image from before the DLC switch, rebuild and push from the test case
root (`3.test_cases/pytorch/openvla-oft`, the directory that holds the
`Dockerfile`). Bump `IMAGE_TAG` if you also moved the Dockerfile's pinned
commit, and keep it in sync with the tag in `env_vars`:

```bash
# From the repo root, cd into the test case directory so the Dockerfile
# and build context are the current path.
cd 3.test_cases/pytorch/openvla-oft

export AWS_REGION=${AWS_REGION:-$(aws configure get region)}
export REGISTRY=$(aws sts get-caller-identity --query Account --output text).dkr.ecr.${AWS_REGION}.amazonaws.com/
export IMAGE_TAG=e4287e9

aws ecr get-login-password --region ${AWS_REGION} \
  | docker login --username AWS --password-stdin \
      763104351884.dkr.ecr.${AWS_REGION}.amazonaws.com

docker buildx build --platform linux/amd64 \
  --build-arg AWS_REGION=${AWS_REGION} \
  --load \
  -f Dockerfile \
  -t ${REGISTRY}openvla-oft:${IMAGE_TAG} \
  .

aws ecr get-login-password --region ${AWS_REGION} \
  | docker login --username AWS --password-stdin ${REGISTRY}
docker image push ${REGISTRY}openvla-oft:${IMAGE_TAG}

# Re-pull on the cluster.
envsubst < kubernetes/libero/libero-finetune.yaml | kubectl delete -f - --ignore-not-found
envsubst < kubernetes/libero/libero-finetune.yaml | kubectl apply -f -
```

### Worker fails with `'PrismaticVisionBackbone' object has no attribute 'set_num_images_in_input'`

**Symptom.** All ranks load the model snapshot successfully (you see
`Loading checkpoint shards: 100%`), then crash with:

```log
File "/openvla-oft/finetune.py", line 633, in finetune
    vla.vision_backbone.set_num_images_in_input(cfg.num_images_in_input)
AttributeError: 'PrismaticVisionBackbone' object has no attribute
'set_num_images_in_input'
```

**Cause.** `trust_remote_code=True` causes `transformers` to load the
model class from the Hub snapshot's `modeling_prismatic.py`, which is
older than the local repo and predates the `set_num_images_in_input`
method. Upstream openvla-oft has a helper, `check_model_logic_mismatch`,
that's supposed to copy the current local `modeling_prismatic.py` and
`configuration_prismatic.py` over the Hub snapshot files before
`from_pretrained` is called. The helper walks `./prismatic/` (relative
path) to find the local files. The cwd at training time is
`/openvla-oft` (the vendored finetune.py copy), but the actual
prismatic package lives at `/opt/openvla-oft/prismatic/` (where the
build did `pip install -e`). The relative walk silently finds nothing,
the Hub stub stays in place, and the older class is loaded.

**Fix.** The `Dockerfile` patches `experiments/robot/openvla_utils.py`
during the build to use the absolute path
`os.walk("/opt/openvla-oft/prismatic/")` so `check_model_logic_mismatch`
locates the current files regardless of cwd. If you see this error,
you are on a pre-patch image. Rebuild and push:

```bash
# From the repo root, cd into the test case directory so the Dockerfile
# and build context are the current path.
cd 3.test_cases/pytorch/openvla-oft

docker buildx build --platform linux/amd64 \
  --build-arg AWS_REGION=${AWS_REGION} \
  --load -f Dockerfile -t ${REGISTRY}openvla-oft:${IMAGE_TAG} .
docker image push ${REGISTRY}openvla-oft:${IMAGE_TAG}

envsubst < kubernetes/libero/libero-finetune.yaml | kubectl delete -f - --ignore-not-found
envsubst < kubernetes/libero/libero-finetune.yaml | kubectl apply -f -
```

### Worker fails with `module 'transformers_modules.<commit>.processing_prismatic' has no attribute 'PrismaticProcessor'`

**Symptom.** The Training Job pod schedules, the model snapshot
downloads, distributed init succeeds, and then one or more ranks crash
during `AutoProcessor.from_pretrained(...)` with:

```log
AttributeError: module 'transformers_modules.<commit>.processing_prismatic'
  has no attribute 'PrismaticProcessor'
```

The traceback runs through `transformers/dynamic_module_utils.py:
get_class_in_module()`.

**Cause.** A concurrent-write race on the dynamic-modules cache.
`trust_remote_code=True` causes `transformers` to copy the model's
custom `processing_prismatic.py` from the snapshot dir into a
per-process cache at
`${HF_HOME}/modules/transformers_modules/<commit>/`. The cache is
process-local, so 8 ranks all copy the same destination file in
parallel. At least one rank reads a partially-written file before the
`class PrismaticProcessor` body has been emitted, so the import
succeeds but the class isn't there.

**Fix.** The vendored `src/finetune.py` wraps the `from_pretrained`
calls (and the upstream `snapshot_download` call) in
`accelerate.PartialState.main_process_first()` so rank 0 finishes the
copy before the other ranks attempt the import. If you see this error,
you are on a pre-fix build of the image. Rebuild and push:

```bash
# From the repo root, cd into the test case directory so the Dockerfile
# and build context are the current path.
cd 3.test_cases/pytorch/openvla-oft

docker buildx build --platform linux/amd64 \
  --build-arg AWS_REGION=${AWS_REGION} \
  --load -f Dockerfile -t ${REGISTRY}openvla-oft:${IMAGE_TAG} .
docker image push ${REGISTRY}openvla-oft:${IMAGE_TAG}

envsubst < kubernetes/libero/libero-finetune.yaml | kubectl delete -f - --ignore-not-found
envsubst < kubernetes/libero/libero-finetune.yaml | kubectl apply -f -
```

If the same race re-appears in a future upstream `from_pretrained`
call we did not gate, the same wrapper pattern (a
`with distributed_state.main_process_first():` block) is the
canonical fix.

### Worker-0 fails with `Gloo connectFullMesh failed ... Connection refused`

**Symptom.** The Training Job pod schedules and starts, the image
imports cleanly, but distributed init crashes with a stack of
`willRetry` warnings followed by:

```log
[/pytorch/third_party/gloo/gloo/transport/tcp/debug_logger.cc:9] ERROR
failed to connect, willRetry=1, retry=1, retryLimit=3, rank=6, size=8,
local=[10.x.y.z]:48822, remote=[10.x.y.z]:9612...,
error=SO_ERROR: Connection refused, remote=[10.x.y.z]:9612...
...
RuntimeError: Gloo connectFullMesh failed with
[/pytorch/third_party/gloo/gloo/transport/tcp/pair.cc:152] timed out
connecting: SO_ERROR: Connection refused
```

The traceback runs through `accelerate/state.py: PartialState()` →
`torch.distributed.init_process_group()` →
`ProcessGroupGloo(store, rank, world_size, ...)`.

**Cause.** PyTorch always creates a **Gloo** helper process group
alongside NCCL for non-tensor metadata, regardless of which backend
the user requests. The Gloo PG honours `GLOO_SOCKET_IFNAME` if set,
but otherwise falls through to `NCCL_SOCKET_IFNAME`. The recipe sets
`NCCL_SOCKET_IFNAME=^lo` to keep inter-node NCCL off loopback, but
that exclusion (no positive match) leaves Gloo without a usable
interface on the K8s pod network. Listener bind() and peer connect()
race on the pod IP and the pod's external interface isn't ready, so
ranks ≠ 0 hit `Connection refused`.

**Fix.** The committed manifest sets `GLOO_SOCKET_IFNAME=lo` in the
Worker pod env so Gloo binds to loopback. This is the right value for
this recipe because all `--nproc_per_node` ranks live inside a single
pod (`replicas: $NUM_NODES` with `NUM_NODES=1`) and therefore share a
network namespace. NCCL is unaffected — it uses EFA via libfabric and
never touches this socket path.

If you have a customised manifest from before this fix, add:

```yaml
- name: GLOO_SOCKET_IFNAME
  value: "lo"
```

next to the existing `NCCL_SOCKET_IFNAME` env var and re-apply the
Training Job.

If you ever scale this recipe to `NUM_NODES > 1`, `lo` is no longer
correct because Gloo helper traffic must cross the pod-network
boundary. Switch the value to the actual pod-network interface name
on your cluster's CNI. EKS VPC CNI exposes it under different names
across AMIs — confirm with a one-off debug pod:

```bash
kubectl run net-debug --rm -it --restart=Never \
  --image=public.ecr.aws/amazonlinux/amazonlinux:2023 \
  -- bash -c 'ip -br -4 addr; echo ---; ip route get 1.1.1.1'
```

Pick the interface that holds the pod's IP (the one in `10.x.y.z/...`,
not `127.0.0.1/8`) and set `GLOO_SOCKET_IFNAME` to that name.

### Worker-0 fails with `libcudart.so.12: cannot open shared object file`

**Symptom.** The Training Job pod schedules and starts, but worker-0
exits during `import` with:

```log
ImportError: libcudart.so.12: cannot open shared object file: No such
file or directory
…
RuntimeError: Failed to import transformers.models.llama.modeling_llama
because of the following error (look up to see its traceback):
libcudart.so.12: cannot open shared object file: No such file or
directory
```

**Cause.** A CUDA toolkit major-version mismatch between the DLC base
and the prebuilt `flash-attn` wheel. `flash-attn` is pulled in
transitively by the moojink/transformers-openvla-oft fork via
`transformers`, and its prebuilt wheel is linked against CUDA 12 — it
asks the loader for `libcudart.so.12` at import time. The
`pytorch-training:2.9.0-gpu-py312-cu130-ubuntu22.04-ec2` DLC ships CUDA
13 (`libcudart.so.13`), so the file flash-attn is looking for does not
exist on the image. PyTorch and NCCL still work — only flash-attn
breaks.

This is unrelated to the TensorFlow info line
`Could not find cuda drivers on your machine, GPU will not be used.`,
which is informational and expected (TF is intentionally CPU-only on
this image; only PyTorch uses GPUs).

**Fix.** The current `Dockerfile` already pins the DLC base to the
CUDA 12.9 tag (`pytorch-training:2.8.0-gpu-py312-cu129-ubuntu22.04-ec2`)
to keep flash-attn happy, and the build-time sanity check imports
`flash_attn` so a future tag bump that reintroduces this mismatch
fails the build instead of training. If you see this error, you are on
a pre-pin `Dockerfile` (or you bumped the DLC tag locally to a CUDA 13
variant). Either revert to the committed tag, or install the CUDA 12
runtime side-by-side following the same pattern as
[`3.test_cases/pytorch/nvrx/Dockerfile`](../../../nvrx/Dockerfile):

```dockerfile
RUN pip install --no-cache-dir nvidia-cuda-runtime-cu12 \
 && ln -sf /usr/local/lib/python3.12/site-packages/nvidia/cuda_runtime/lib/libcudart.so.12 \
       /usr/local/cuda/lib64/libcudart.so.12 \
 && ldconfig 2>/dev/null || true
```

### Build fails with `Could not find a version that satisfies the requirement tensorflow==2.15.0`

**Symptom.** `docker buildx build` exits non-zero during
`pip install -e /opt/openvla-oft` with one of two pip errors:

```log
ERROR: Could not find a version that satisfies the requirement tensorflow==2.15.0 (from openvla-oft)
(from versions: 2.16.0rc0, 2.16.1, …, 2.21.0)
```

or

```log
ERROR: Cannot install openvla-oft and openvla-oft==0.0.1 because these
package versions have conflicting dependencies.
The conflict is caused by:
    openvla-oft 0.0.1 depends on tensorflow<2.17 and >=2.16
    dlimp 0.0.1 depends on tensorflow==2.15.0
```

**Cause.** Upstream openvla-oft pins `tensorflow==2.15.0`, which has no
Python 3.12 wheels (TF 2.15 was the last py3.11-only release; py3.12
support starts at TF 2.16). The DLC base ships Python 3.12. Upstream's
`dlimp` dependency carries the same pin, so even after relaxing the
openvla-oft pin alone, pip's resolver can't satisfy both.

**Fix.** The current `Dockerfile` patches both projects during the
build:

- Pre-clones `dlimp` to `/opt/dlimp` and rewrites its `setup.py` to
  relax `tensorflow==2.15.0` → `tensorflow>=2.16,<2.17`.
- Rewrites openvla-oft's `pyproject.toml` `dlimp @ git+…` reference to
  `dlimp @ file:///opt/dlimp` so pip uses the patched local copy.
- Applies the same TF relaxation, `tensorflow_datasets>=4.9.4` bump,
  and `tensorflow_graphics` removal to openvla-oft's `pyproject.toml`,
  plus the lazy-import patch to `droid_utils.py`.

The build then runs an `import` sanity check at the end (`tf`, `tfds`,
and `from prismatic.vla.datasets import RLDSDataset`) so any future
regression fails the build instead of training.

If you see this error, you are on a pre-patch `Dockerfile`. Pull the
latest version of this directory and rebuild.

### Download Job pod fails with `RunContainerError`: `NVML: Driver Not Loaded`

**Symptom.** `kubectl get pod -l app=openvla-oft-libero-download` shows the
Download Job pod cycling through `RunContainerError` → `CrashLoopBackOff`
within seconds. `kubectl logs` returns nothing because the entrypoint never
ran. `kubectl describe pod` shows:

```log
failed to create containerd task: failed to create shim task: OCI runtime
create failed: ... failed to initialize NVML: Driver Not Loaded
```

**Cause.** The `openvla-oft` image inherits `NVIDIA_VISIBLE_DEVICES=all`
from the `nccl-tests` base. With the NVIDIA Container Toolkit in CDI
auto-mode, `nvidia-container-runtime` tries to enumerate GPUs on container
create. On a node without the NVIDIA driver loaded — including any CPU
node the Download Job lands on — that enumeration fails before the
entrypoint runs.

**Fix.** The committed `libero-download.yaml` already sets
`NVIDIA_VISIBLE_DEVICES=void` in the container `env:` block to opt out of
GPU injection. If your local copy predates that, add the same env var or
re-pull the manifest. The Training Job is unaffected because it requests
`nvidia.com/gpu` and lands on a GPU node where the driver is loaded.

### Dataset PVC is `Pending` (unbound)

**Symptom.** `kubectl get pvc` shows the PVC stuck in `Pending`, or
`kubectl describe pod` on a Job pod shows
`FailedScheduling: persistentvolumeclaim "<name>" not found` /
`...pending`.

**Fix.** You have not applied a PVC yet, or the FSx CSI driver has not
finished provisioning. Apply either `pvc-fsx-lustre-dynamic.yaml`
(EKS, dynamic) or `pv-fsx-lustre-static.yaml` (HyperPod, static) as
described in section 2, and wait for the FSx filesystem to reach
`AVAILABLE` before re-checking.

### `CreateContainerConfigError: secret "openvla-oft-secrets" not found`

**Symptom.** Pods from either Job stay in `CreateContainerConfigError`.
`kubectl describe pod` shows the missing-secret message.

**Fix.** The `optional: true` flag on the `secretKeyRef` only makes individual
keys optional; a missing Secret resource still blocks pod start. Run the
`kubectl create secret generic openvla-oft-secrets ...` command from section 3
in the target namespace.

### `TASK_SUITE` unset or empty at render time

**Symptom.** `source env_vars` or `envsubst < libero-*.yaml` exits non-zero
with a message that names `TASK_SUITE` and lists the five accepted values.

**Fix.** Set both `TASK_SUITE` and `TASK_SUITE_DNS` in the current shell
before sourcing `env_vars`:

```bash
export TASK_SUITE=libero_spatial_no_noops
export TASK_SUITE_DNS="${TASK_SUITE//_/-}"
source env_vars
```

### `TASK_SUITE` not in the allow-list

**Symptom.** The Download Job pod exits with status `2` within seconds of
starting. The pod log shows:

```log
ERROR: TASK_SUITE='<bad>' not in allow-list: libero_spatial_no_noops libero_object_no_noops libero_goal_no_noops libero_10_no_noops all
```

**Fix.** Set `TASK_SUITE` to exactly one of the five allow-listed values and
re-render:

```bash
export TASK_SUITE=libero_10_no_noops
export TASK_SUITE_DNS="${TASK_SUITE//_/-}"
source env_vars
envsubst < libero-download.yaml | kubectl apply -f -
```

### Hugging Face rate limit or 401/403

**Symptom.** The Download Job pod exits non-zero. Stderr contains a 401/403
or rate-limit message from `huggingface-cli`.

**Fix.** Populate `HF_TOKEN` in the Secret:

```bash
export HF_TOKEN=<your-hugging-face-token>
kubectl delete secret openvla-oft-secrets
kubectl create secret generic openvla-oft-secrets \
  --from-literal=HF_TOKEN="${HF_TOKEN}" \
  --from-literal=WANDB_API_KEY="${WANDB_API_KEY:-}"
```

Then re-apply the Download Job. An `HF_TOKEN` is not strictly required for
the public `openvla/modified_libero_rlds` dataset, but it unblocks rate-limit
and anonymous-access edge cases.

### Training Job reads a PVC with no (or malformed) dataset

**Symptom.** The Training Job worker-0 exits non-zero within the first ten
minutes of startup. The pod log mentions a path under `/data/datasets/rlds/`
(missing suite directory, missing `dataset_info.json`, or missing shards).

**Fix.** Re-run the Download Job for the affected `TASK_SUITE`, then confirm
the layout with `verify-tfds-layout.sh` from section 5 before re-submitting:

```bash
export TASK_SUITE=<your-suite>
export TASK_SUITE_DNS="${TASK_SUITE//_/-}"
source env_vars
envsubst < libero-download.yaml | kubectl apply -f -
# wait for completion, then verify
```

### CUDA OOM at step 0 (GPU has <80 GiB VRAM)

**Symptom.** Training Job worker logs show a CUDA out-of-memory error at or
near step 0, typically during the first forward pass.

**Fix.** The default recipe targets 80 GiB GPUs (A100 80 GiB or H100 80 GiB).
Either switch the node pool to one of those classes, or reduce the memory
footprint by lowering `--batch_size` and raising `--grad_accumulation_steps`
in `libero-finetune.yaml` as described in section 1. Both flags must change
together to keep the effective batch size constant.

## Related walkthroughs

- Parent test-case README: [`../../README.md`](../../README.md) — Dockerfile
  rationale, layout, references.

## References

The hyperparameter set used by this recipe comes directly from the upstream
[LIBERO.md](https://github.com/moojink/openvla-oft/blob/main/LIBERO.md) tuning
guide. The Training Job passes those flags verbatim to `/openvla-oft/finetune.py`;
nothing is re-tuned for this recipe.
