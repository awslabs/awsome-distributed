# Isaac Lab Distributed RL Training on AWS

Train the [Unitree H1 humanoid robot](https://www.unitree.com/h1) to walk on rough terrain using distributed reinforcement learning on AWS. This test case demonstrates multi-node GPU training with [NVIDIA Isaac Lab](https://github.com/isaac-sim/IsaacLab) (v2.3.2) and Isaac Sim 5.1.0, using the [skrl](https://skrl.readthedocs.io/) framework with PPO for the `Isaac-Velocity-Rough-H1-v0` task.

## Key Features

| Feature | Description |
|---------|-------------|
| Multi-node distributed RL | PyTorch DDP via `torchrun` across 2+ nodes with 4-8 GPUs each |
| Dual compute backends | Amazon SageMaker HyperPod EKS (Persistent) and Amazon SageMaker Training Jobs (Ephemeral) |
| GPU-accelerated simulation | 4096 parallel environments on NVIDIA Isaac Sim |
| MLflow experiment tracking | Batched metric logging via background thread |
| Config-driven generation | Single `config.yaml` generates all Kubernetes manifests and launch scripts |

## Supported Instances

Isaac Sim is built on NVIDIA Omniverse and uses the Omniverse RTX Renderer, which requires GPUs with hardware RT Cores. The G family of AWS GPU instances is suitable for Isaac Lab workloads; the P family is not, as it uses data center GPUs without RT Cores. See the [Isaac Sim 5.1 requirements page](https://docs.isaacsim.omniverse.nvidia.com/5.1.0/installation/requirements.html) for the full list of supported and unsupported hardware.


| Instance family | GPU Type and Generation | RT Cores / Isaac Sim Compatibility |
|---|---|---|
| ml.g5 | NVIDIA A10G (Ampere) | Yes |
| ml.g6 | NVIDIA L4 (Ada Lovelace) | Yes |
| ml.g6e | NVIDIA L40S (Ada Lovelace) | Yes |
| ml.g7e | NVIDIA RTX PRO 6000 (Blackwell) | Yes |
| ml.p4d, ml.p4de, ml.p5, ml.p5e, ml.p5en, ml.p6-b200, ml.p6-b300, ml.p6e-gb200 | NVIDIA A100 (Ampere), H100 / H200 (Hopper), B200 / B300 / GB200 (Blackwell) | No |


## Prerequisites

To run distributed Isaac Lab training, you need:

- AWS CLI v2 with configured credentials
- Python 3.10+ with `pyyaml` and `boto3`
- Docker (for building the container image)
- One of:
  - **HyperPod EKS**: SageMaker HyperPod cluster with [Kubeflow Training Operator](https://github.com/kubeflow/training-operator) and FSx for Lustre
  - **SageMaker Training Jobs**: IAM role with SageMaker permissions and S3 bucket

Cluster creation instructions can be found in the [SageMaker HyperPod EKS Workshop](https://awslabs.github.io/ai-on-sagemaker-hyperpod/docs/eks-orchestration/getting-started).

> **EFA:** The container image includes the AWS EFA userspace stack (libfabric + aws-ofi-nccl). On EFA-capable instances (`ml.g6.12xlarge` and above, `ml.g6e`, `ml.p4d`, `ml.p5`), NCCL automatically uses EFA for inter-node collectives. No additional configuration is required.

## 1. Build Container Image

From the repository root, build a container image based on `nvcr.io/nvidia/isaac-sim:5.1.0` with Isaac Lab v2.3.2 and the training scripts:

```bash
export AWS_REGION=$(aws configure get region)
export ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
export REGISTRY=${ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com
export IMAGE_NAME=isaaclab-sagemaker
export IMAGE_TAG=5.1.0

docker build -t ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG} -f docker/Dockerfile .
```

## 2. Push Container Image to Amazon ECR

```bash
# Create repository if needed
aws ecr describe-repositories --repository-names ${IMAGE_NAME} 2>/dev/null || \
  aws ecr create-repository --repository-name ${IMAGE_NAME}

# Login and push
aws ecr get-login-password --region ${AWS_REGION} | \
  docker login --username AWS --password-stdin ${REGISTRY}
docker push ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}
```

> **Note:** The image is ~20 GB. First pull on cluster nodes takes 5-7 minutes.

## 3. Configure

```bash
cp config.yaml.example config.yaml
# Edit config.yaml with your AWS account, ECR, FSx, and cluster details
```

Key sections in `config.yaml`:

| Section | What to configure |
|---------|-------------------|
| `aws` | Account ID, region |
| `ecr` | Repository name, image tag |
| `s3` | Bucket for scripts and training output |
| `training` | Task name, max_iterations, framework (`skrl`/`rsl_rl`/`rl_games`/`sb3`) |
| `hyperpod_eks` | FSx file system, instance type, GPUs per node, num_nodes, log directory |
| `sagemaker_training` | IAM role ARN, instance type/count, volume size |
| `mlflow` | (Optional) Tracking server ARN, experiment name |

## 4. Generate Manifests

```bash
python generate.py                    # generates into generated/
python generate.py --dry-run          # preview without writing
python generate.py --config my.yaml   # use alternate config
```

This produces:

```
generated/
├── storage.yaml              # FSx PersistentVolume + PersistentVolumeClaim
├── training-job.yaml         # Kubeflow PyTorchJob (single- or multi-node)
├── tensorboard.yaml          # TensorBoard Deployment + ClusterIP Service
├── viz-eks-webrtc-pod.yaml   # Isaac Sim visualization pod with WebRTC
└── launch-sm-training.py     # SageMaker Training Job launcher script
```

## 5. Deploy Storage (One-Time)

The training pods need shared storage for checkpoints and logs. Create the FSx PersistentVolume and PersistentVolumeClaim:

```bash
kubectl apply -f generated/storage.yaml
kubectl get pvc -w   # wait for STATUS=Bound
```

> **Note:** If your cluster already has an FSx PVC (e.g., from HyperPod setup), set `hyperpod_eks.storage.fsx_pvc_name` in config.yaml to match the existing PVC name and skip this step.

## 6. Launch Training

### Option A: HyperPod EKS (Kubernetes)

```bash
# Deploy the PyTorchJob
kubectl apply -f generated/training-job.yaml

# Monitor training
kubectl get pytorchjobs
kubectl logs -f isaaclab-h1-master-0
```

With `num_nodes: 2` and `gpus_per_node: 4`, this creates a Master + 1 Worker pod, each with 4 GPUs. `torchrun` coordinates distributed training across all 8 GPUs.

### Option B: SageMaker Training Jobs

```bash
# Upload entrypoint to S3 (one-time)
aws s3 cp scripts/sm-train-entrypoint.sh s3://<bucket>/scripts/sm-train-entrypoint.sh

# Launch training job
python generated/launch-sm-training.py

# Or with overrides
python generated/launch-sm-training.py --iterations 500
python generated/launch-sm-training.py --dry-run
```

## 7. Monitor Training

```bash
# HyperPod EKS -- watch training progress
kubectl logs -f isaaclab-h1-master-0

# HyperPod EKS -- TensorBoard
kubectl apply -f generated/tensorboard.yaml
kubectl port-forward svc/isaaclab-tensorboard 6006:6006
# Open http://localhost:6006

# SageMaker Training Jobs -- check status
aws sagemaker describe-training-job \
  --training-job-name <job-name> \
  --query '{Status: TrainingJobStatus, SecondaryStatus: SecondaryStatus}'
```

## 8. Cleanup

```bash
# Delete training job
kubectl delete pytorchjob isaaclab-h1

# Delete TensorBoard and viz pods
kubectl delete -f generated/tensorboard.yaml
kubectl delete -f generated/viz-eks-webrtc-pod.yaml
```

---

## MLflow Integration (Optional)

MLflow integration is implemented as a runtime hook (`scripts/mlflow_isaaclab.py`) invoked by `scripts/run_train.py` before Isaac Lab's `train.py` runs. It monkey-patches `SummaryWriter.add_scalar` to mirror metrics to a background thread that flushes batches via `MlflowClient.log_batch` every 2 seconds. Enabled when `MLFLOW_TRACKING_URI` is set; no-op otherwise.

**Configuration:**

Set in `config.yaml`:
```yaml
mlflow:
  tracking_uri: "arn:aws:sagemaker:<region>:<account>:mlflow-tracking-server/<name>"
  experiment_name: "isaaclab-h1"
  assume_role_arn: ""  # Required for Studio MLflow Apps accessed from non-Studio callers
```

**IAM requirements:** The training pod's execution role needs `sagemaker-mlflow:*` permission on the tracking server ARN, plus S3 access to the MLflow artifact bucket.

---
## Source Files

| File | Purpose |
|------|---------|
| `generate.py` | Config-driven manifest generator (Python `string.Template`) |
| `config.yaml.example` | Configuration template with all options documented |
| `docker/Dockerfile` | Isaac Sim 5.1.0 + Isaac Lab v2.3.2 + training dependencies + AWS EFA stack |
| `scripts/mlflow_isaaclab.py` | MLflow runtime hook: patches SummaryWriter + argparse, batched log_batch |
| `scripts/run_train.py` | Entrypoint shim: installs MLflow hook then runs train.py via runpy |
| `scripts/sm-train-entrypoint.sh` | SageMaker BYOC entrypoint (parses `resourceconfig.json`, launches `torchrun`) |
| `templates/*.tpl` | Kubernetes manifest and Python script templates |
| `viz-scripts/` | DCV visualization helpers for EC2 workshop path |

## References

- [NVIDIA Isaac Lab](https://github.com/isaac-sim/IsaacLab) -- RL framework built on Isaac Sim
- [skrl Documentation](https://skrl.readthedocs.io/) -- Modular RL library
- [Kubeflow Training Operator](https://github.com/kubeflow/training-operator) -- PyTorchJob CRD for Kubernetes
- [NVIDIA Isaac Lab on AWS Workshop](https://catalog.workshops.aws/nvidia-isaac-lab-on-aws)
- [SageMaker MLflow](https://docs.aws.amazon.com/sagemaker/latest/dg/mlflow.html)
