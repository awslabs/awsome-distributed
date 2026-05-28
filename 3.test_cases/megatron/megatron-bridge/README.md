<!-- Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved. -->
<!-- SPDX-License-Identifier: MIT-0 -->

# Megatron-Bridge: Qwen 3 Pretraining on AWS

[Megatron-Bridge](https://github.com/NVIDIA-NeMo/Megatron-Bridge) ([PyPI](https://pypi.org/project/megatron-bridge/)) is a PyTorch-native library within the NeMo Framework that bridges Hugging Face models with [Megatron-Core](https://github.com/NVIDIA/Megatron-LM/tree/main/megatron/core) for high-performance distributed training. It provides bidirectional checkpoint conversion, built-in training recipes, and support for advanced parallelism strategies (TP, PP, CP, EP).

This guide walks through pretraining [Qwen 3](https://huggingface.co/Qwen) models using
Megatron-Bridge on an EKS or SageMaker HyperPod EKS cluster with Kubeflow PyTorchJob
and AWS EFA networking.

## Supported Models

Megatron-Bridge supports Qwen3, Qwen3-MoE, Llama 2/3, DeepSeek V2/V3, Gemma, Mistral, and many more. See the [full list](https://github.com/NVIDIA-NeMo/Megatron-Bridge#supported-models).

## 1. Prerequisites

### Cluster Requirements

- An EKS or SageMaker HyperPod EKS cluster with 2x ml.p5.48xlarge/ml.p5en.48xlarge nodes
- [NVIDIA device plugin](https://github.com/NVIDIA/k8s-device-plugin) installed
- [EFA device plugin](https://github.com/aws/eks-charts/tree/master/stable/aws-efa-k8s-device-plugin) installed
- [Kubeflow Training Operator](https://github.com/kubeflow/training-operator) with PyTorchJob CRD
- FSx for Lustre PersistentVolumeClaim (`fsx-claim`) bound and accessible
- Docker installed locally for building the container image
- AWS CLI configured with access to ECR

## 2. Build the Container Image

```bash
export AWS_REGION=$(aws ec2 describe-availability-zones --output text --query 'AvailabilityZones[0].[RegionName]')
export ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
export REGISTRY=${ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/
export IMAGE_TAG=latest

docker build -f aws-megatron-bridge.Dockerfile -t ${REGISTRY}megatron-bridge-qwen3:${IMAGE_TAG} .
```

## 3. Push Container Image to Amazon ECR

```bash
# Create the ECR repository (if it does not already exist)
REGISTRY_COUNT=$(aws ecr describe-repositories | grep \"megatron-bridge-qwen3\" | wc -l)
if [ "$REGISTRY_COUNT" == "0" ]; then
    aws ecr create-repository --repository-name megatron-bridge-qwen3
fi

# Authenticate to ECR
echo "Logging in to $REGISTRY ..."
aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin $REGISTRY

# Push the image
docker image push ${REGISTRY}megatron-bridge-qwen3:${IMAGE_TAG}
```

After pushing, the image URI will be:

```
${ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/megatron-bridge-qwen3:latest
```

Use this as the `REPO_URI` environment variable in the steps below.

## 4. Download Model Weights

Before training, download the Qwen 3 model weights to FSx for Lustre. This is a
one-time operation.

```bash
# Set variables
export REPO_URI=${REGISTRY}megatron-bridge-qwen3:${IMAGE_TAG}
export HF_MODEL=Qwen/Qwen3-8B            # Choose: Qwen3-0.6B, Qwen3-1.7B, Qwen3-4B, Qwen3-8B, Qwen3-14B, Qwen3-32B
export MODEL_SIZE=8b                       # Match the model: 0.6b, 1.7b, 4b, 8b, 14b, 32b

# Create a Kubernetes Secret for HuggingFace token (one-time setup)
kubectl create secret generic hf-token --from-literal=token=<your-huggingface-token>

# Generate and apply the download job
envsubst '$REPO_URI $HF_MODEL $MODEL_SIZE' < kubernetes/qwen3/manifests/download-model-job.yaml-template | kubectl apply -f -

# Monitor the download
kubectl logs -f job/download-qwen3-model

# Verify completion
kubectl get job download-qwen3-model
```

## 5. Distributed Training

### 5.1 Configure Training Parameters

```bash
# Container image
export REPO_URI=${REGISTRY}megatron-bridge-qwen3:${IMAGE_TAG}

# Cluster topology
export NUM_NODES=2                    # Number of nodes
export GPU_PER_NODE=8                 # GPUs per node (8 for p5.48xlarge)
export EFA_PER_NODE=32                # EFA adapters per node (32 for p5.48xlarge)
export FI_PROVIDER=efa                # Libfabric provider

# Model configuration
export MODEL_SIZE=8b                  # Qwen3 model size
export TENSOR_PARALLEL=4              # Tensor parallelism degree
export PIPELINE_PARALLEL=1            # Pipeline parallelism degree

# Training hyperparameters
export SEQ_LENGTH=4096                # Sequence length
export GLOBAL_BATCH_SIZE=16           # Global batch size
export MICRO_BATCH_SIZE=1             # Micro batch size per GPU
export TRAIN_ITERS=100                # Number of training iterations
```

### 5.2 Launch Training

```bash
# Generate the PyTorchJob manifest and apply
envsubst '$REPO_URI $NUM_NODES $GPU_PER_NODE $EFA_PER_NODE $FI_PROVIDER $MODEL_SIZE $TRAIN_ITERS $SEQ_LENGTH $GLOBAL_BATCH_SIZE $MICRO_BATCH_SIZE $TENSOR_PARALLEL $PIPELINE_PARALLEL' \
  < kubernetes/qwen3/manifests/pytorchjob.yaml-template | kubectl apply -f -

# Monitor training logs (wait for pods to start)
kubectl logs -f megatron-bridge-qwen3-worker-0

# Check job status
kubectl get pytorchjob megatron-bridge-qwen3
```

### 5.3 Clean Up

```bash
kubectl delete pytorchjob megatron-bridge-qwen3
kubectl delete deployment etcd
kubectl delete service etcd
kubectl delete job download-qwen3-model
```

## 6. Model Sizes and Recommended Parallelism

The table below provides recommended parallelism settings for each Qwen 3 model size
on 2x p5.48xlarge (16 GPUs total):

| Model | Parameters | TP | PP | Nodes (p5.48xlarge) | Notes |
|-------|-----------|----|----|---------------------|-------|
| Qwen3-0.6B | 0.6B | 1 | 1 | 1 | Fits on single GPU |
| Qwen3-1.7B | 1.7B | 1 | 1 | 1 | Fits on single GPU |
| Qwen3-4B | 4B | 2 | 1 | 1 | 2-way tensor parallel |
| Qwen3-8B | 8B | 4 | 1 | 1 | 4-way tensor parallel |
| Qwen3-14B | 14B | 8 | 1 | 1 | Full node tensor parallel |
| Qwen3-32B | 32B | 8 | 2 | 2 | TP + PP with activation recompute |

## 7. Validated Training Output

The following sections capture actual log output from running this sample end-to-end
on a SageMaker HyperPod EKS cluster with 2x `ml.p5.48xlarge` (16x H100 80GB).

### 7.1 Cluster Topology

```
$ kubectl get nodes -o wide
NAME                           STATUS   ROLES    AGE   VERSION               INTERNAL-IP    OS-IMAGE
hyperpod-i-008789534bbb4c33f   Ready    <none>   12d   v1.33.5-eks-ecaa3a6   10.1.205.104   Amazon Linux 2023
hyperpod-i-0a8b955807d0df904   Ready    <none>   12d   v1.33.5-eks-ecaa3a6   10.1.232.216   Amazon Linux 2023

GPUs and EFA per node:
  hyperpod-i-008789534bbb4c33f: GPUs=8, EFA=32
  hyperpod-i-0a8b955807d0df904: GPUs=8, EFA=32
```

### 7.2 Training Configuration

| Parameter | Value |
|-----------|-------|
| Model | Qwen3-0.6B |
| Nodes | 2x ml.p5.48xlarge |
| GPUs | 16 (8 per node) |
| EFA adapters | 32 per node |
| Parallelism | TP=1, PP=1 (data parallel) |
| Sequence length | 2048 |
| Global batch size | 16 |
| Micro batch size | 1 |
| Training iterations | 10 |

### 7.3 Rendezvous and Launch

```
Starting elastic_operator with launch configs:
  entrypoint       : /workspace/pretrain_qwen3.py
  min_nodes        : 2
  max_nodes        : 2
  nproc_per_node   : 8
  rdzv_backend     : etcd
  rdzv_endpoint    : etcd:2379
  max_restarts     : 100

Rendezvous complete for workers. Result:
  master_addr=megatron-bridge-qwen3-worker-1
  master_port=53801
  group_world_size=2
  global_ranks=[0, 1, 2, 3, 4, 5, 6, 7]  (per node)
  global_world_sizes=[16, 16, 16, 16, 16, 16, 16, 16]
```

### 7.4 EFA Verification

The NCCL logs confirm that AWS EFA is active with RDMA transport and all 32 NICs
detected per node:

```
NCCL INFO NET/OFI Initializing aws-ofi-nccl 1.18.0
NCCL INFO NET/OFI Using Libfabric version 2.4
NCCL INFO NET/OFI Using transport protocol RDMA (platform set)
NCCL INFO NET/OFI Selected provider is efa, fabric is efa-direct (found 32 nics)
NCCL INFO NET/OFI Configuring AWS-specific options
NCCL INFO NET/OFI Internode latency set at 75.0 us

NCCL INFO TUNER/Plugin: Using nccl_ofi_tuner (v3)
NCCL INFO Successfully loaded external tuner plugin /opt/amazon/ofi-nccl/lib/libnccl-net.so
NCCL INFO NET/OFI Region base Tuner is chosen for platform: p5.48xlarge
```

### 7.5 Model Initialization

```
[Megatron-Bridge] Qwen3-0.6B pretraining
[Megatron-Bridge] World size: 16, TP=1, PP=1
[Megatron-Bridge] Model path: /fsx/qwen3/0.6b
[Megatron-Bridge] Seq=2048, GBS=16, Iters=10
[Megatron-Bridge] Creating bridge and loading model...
[Megatron-Bridge] Loading weights from /fsx/qwen3/0.6b
[Megatron-Bridge] Model built: 0.60B params, 0.60B trainable
```

### 7.6 Training Results

```
[Megatron-Bridge] Starting training for 10 iterations...
  step   1/10 | loss: 0.6869 | time: 1.89s | tokens/s: 17,351
  step   2/10 | loss: -4.3676 | time: 0.14s | tokens/s: 241,682
  step   3/10 | loss: -8.8785 | time: 0.11s | tokens/s: 306,938
  step   4/10 | loss: -14.0235 | time: 0.10s | tokens/s: 328,907
  step   5/10 | loss: -18.2283 | time: 0.10s | tokens/s: 329,265
  step   6/10 | loss: -19.9766 | time: 0.10s | tokens/s: 330,300
  step   7/10 | loss: -23.3931 | time: 0.10s | tokens/s: 330,264
  step   8/10 | loss: -26.0851 | time: 0.10s | tokens/s: 329,648
  step   9/10 | loss: -29.8682 | time: 0.11s | tokens/s: 306,454
  step  10/10 | loss: -32.5855 | time: 0.10s | tokens/s: 326,035

[Megatron-Bridge] Training complete!
```

Steady-state throughput: **~330K tokens/s** across 16x H100 GPUs (2 nodes) with
Qwen3-0.6B and TP=1, PP=1.

### 7.7 Job Completion

```
$ kubectl get pytorchjob megatron-bridge-qwen3
NAME                    STATE       AGE
megatron-bridge-qwen3   Succeeded   8m

PyTorchJob default/megatron-bridge-qwen3 successfully completed.
  Worker: 2/2 succeeded
  Start: 2026-04-27T10:11:38Z
  End:   2026-04-27T10:19:21Z
```

## 8. Appendix

### 8.1 Benchmark Mode

For pure throughput benchmarking, the training script uses mock data by default
(no `--hf-model-path` required for mock). To benchmark without downloading weights:

```bash
# Remove the --hf-model-path argument from the PyTorchJob template
# The script will use mock data and random weights
```

### 8.2 Using Real Data

To use real training data, preprocess it with Megatron-LM's data preprocessing
tools and set the `--data-path` argument. Alternatively, leverage Megatron-Bridge's
built-in dataset blend configuration.
