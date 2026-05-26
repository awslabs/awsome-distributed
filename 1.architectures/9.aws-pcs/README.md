# AWS Parallel Computing Service Distributed Training Reference Architecture

This repository provides reference architectures and deployment templates for setting up distributed training clusters using [AWS Parallel Computing Service (PCS)](https://aws.amazon.com/pcs/). These architectures are optimized for machine learning workloads and include configurations for high-performance computing instances (P and Trn EC2 families) with shared filesystems (FSx for Lustre and OpenZFS).

## Key Features

- **Pre-configured for ML workloads**: Optimized for distributed training with Slurm scheduler
- **High-performance storage**: FSx for Lustre (high-throughput shared) and OpenZFS (home directories)
- **Flexible compute options**: Support for On-Demand, On-Demand Capacity Reservations (ODCR), and Capacity Blocks for ML
- **Advanced networking**: Elastic Fabric Adapter (EFA) support for multi-node training
- **Custom AMI building**: Automated DLAMI creation with PCS agent, Slurm, Enroot, and Pyxis
- **Modular deployment**: Deploy complete clusters or individual components via nested CloudFormation stacks

## Architecture

![AWS PCS diagram](./images/ml-pcs-architecture.png)

The architecture includes:
- VPC with public/private subnets
- FSx for Lustre for high-performance shared storage
- FSx for OpenZFS for home directories
- PCS cluster with Slurm scheduler (25.05 or 25.11)
- Login node group (public subnet)
- Compute node groups (private subnet)
- Optional custom DLAMI with ML frameworks and container runtime

## Deployment Options

### Option 1: Complete Cluster (Recommended)

Deploy the complete PCS ML cluster with a single nested CloudFormation stack:

[![Launch](images/launch-stack.svg)](https://console.aws.amazon.com/cloudformation/home#/stacks/quickcreate?templateUrl=https://awsome-distributed-ai.s3.amazonaws.com/templates/pcs-ml-cluster-deploy-all.yaml&stackName=pcs-ml-cluster)

**What gets deployed:**
- ✅ VPC with public/private subnets, NAT gateway, S3 endpoint
- ✅ FSx for Lustre (high-throughput shared storage)
- ✅ FSx for OpenZFS (home directories)
- ✅ Custom DLAMI with PCS agent and Slurm
- ✅ AWS PCS cluster with Slurm scheduler
- ✅ Login node group (e.g., m6i.4xlarge)
- ✅ CPU compute node group (e.g., c6i.4xlarge)
- ⚙️ Additional on-demand GPU compute node group (optional, e.g., g5.12xlarge)
- ⚙️ Additional P-series compute node group with On-Demand Capacity Reservation (ODCR) or Capacity Blocks for ML (optional, e.g., p5.48xlarge)

**Key Parameters:**
- `PrimarySubnetAZ`: Availability Zone for deployment (required)
- `BuildAMI`: Build custom DLAMI (`true`/`false`, default: `true`)
- `DeployOnDemandCNG`: Deploy additional on-demand GPU queue (`true`/`false`, default: `false`)
- `DeployPseriesCNG`: Deploy P-series queue with ODCR or Capacity Blocks for ML (`true`/`false`, default: `false`)
- `CapacityReservationId`: Capacity Reservation ID (required if deploying in Capacity Blocks for ML)

**Example deployment with GPU queue:**
```bash
aws cloudformation create-stack \
  --stack-name my-pcs-cluster \
  --template-url https://awsome-distributed-ai.s3.amazonaws.com/templates/pcs-ml-cluster-deploy-all.yaml \
  --parameters \
    ParameterKey=PrimarySubnetAZ,ParameterValue=us-east-1a \
    ParameterKey=DeployOnDemandCNG,ParameterValue=true \
    ParameterKey=OnDemandInstanceType,ParameterValue=g5.12xlarge \
    ParameterKey=OnDemandMaxCount,ParameterValue=8 \
  --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM
```

### Option 2: Individual Components

Deploy components separately for more control:

| Component | Description | Deploy | When to Use |
|-----------|-------------|--------|-------------|
| **Prerequisites** | VPC, subnets, security groups, FSx filesystems | [<kbd>Deploy 🚀</kbd>](https://console.aws.amazon.com/cloudformation/home#/stacks/quickcreate?templateUrl=https://awsome-distributed-ai.s3.amazonaws.com/templates/ml-cluster-prerequisites.yaml&stackName=pcs-prerequisites) | Use existing VPC or customize networking |
| **PCS-ready DLAMI with Enroot/Pyxis** | Adds Enroot/Pyxis to PCS-ready DLAMI | [<kbd>Deploy 🚀</kbd>](https://console.aws.amazon.com/cloudformation/home#/stacks/quickcreate?templateUrl=https://awsome-distributed-ai.s3.amazonaws.com/templates/pcs-ready-dlami-with-enroot-pyxis.yaml&stackName=pcs-dlami) | Build custom AMI with container support |
| **PCS Cluster** | Main cluster with login and compute nodes | [<kbd>Deploy 🚀</kbd>](https://console.aws.amazon.com/cloudformation/home#/stacks/quickcreate?templateUrl=https://awsome-distributed-ai.s3.amazonaws.com/templates/cluster.yaml&stackName=pcs-cluster) | Deploy cluster to existing VPC/FSx |
| **Add CNG (Single NIC)** | Additional compute nodes with single network interface | [<kbd>Deploy 🚀</kbd>](https://console.aws.amazon.com/cloudformation/home#/stacks/quickcreate?templateUrl=https://awsome-distributed-ai.s3.amazonaws.com/templates/add-cng.yaml&stackName=pcs-add-cng) | Add CPU/GPU queues (G5, G6e, G6 etc.) |
| **Add CNG (Multi NIC)** | P5/P6 nodes with 16/32 network interfaces (On-Demand or Capacity Blocks for ML) | [<kbd>Deploy 🚀</kbd>](https://console.aws.amazon.com/cloudformation/home#/stacks/quickcreate?templateUrl=https://awsome-distributed-ai.s3.amazonaws.com/templates/add-cng-p5.yaml&stackName=pcs-add-cng-p5) | Add P-series (P5/P5e/P5en, P6-B200 instances) |

### Option 3: Manual Step-by-Step

For detailed step-by-step deployment instructions, see the [AI/ML for AWS Parallel Computing Service Workshop](https://catalog.workshops.aws/ml-on-pcs/).

---

## CloudFormation Templates

### Main Templates

| Template | Purpose | Nested Stacks |
|----------|---------|---------------|
| [`pcs-ml-cluster-deploy-all.yaml`](./assets/pcs-ml-cluster-deploy-all.yaml) | All-in-one nested stack deployment | Prerequisites + DLAMI + Cluster + Optional CNGs |
| [`ml-cluster-prerequisites.yaml`](./assets/ml-cluster-prerequisites.yaml) | VPC, subnets, FSx for Lustre/OpenZFS | Standalone |
| [`pcs-ready-dlami-with-enroot-pyxis.yaml`](./assets/pcs-ready-dlami-with-enroot-pyxis.yaml) | EC2 Image Builder for PCS AMI with Enroot/Pyxis | Standalone |
| [`cluster.yaml`](./assets/cluster.yaml) | PCS cluster with login and compute nodes | Standalone |

### Add-on Templates

| Template | Purpose | Network Interface | Prerequisites |
|----------|---------|-------------------|---------------|
| [`add-cng.yaml`](./assets/add-cng.yaml) | Add compute node group for CPU/GPU instances | Single | Existing PCS cluster |
| [`add-cng-p5.yaml`](./assets/add-cng-p5.yaml) | Add P5/P6 compute nodes (On-Demand or Capacity Block) | Multi (16/32 EFA) | Existing PCS cluster (+ Capacity Reservation for CB) |

---

## Supported Compute Options

### 1. Single Network Interface Instances (use `add-cng.yaml`)
Standard instances with single network interface. Suitable for:
- Development and testing
- Workloads with unpredictable demand
- Short-duration training jobs
- Small to medium scale distributed training

**Recommended instance types:**
- **CPU**: `c6i.32xlarge`, `c7i.48xlarge`, `c7a.48xlarge`
- **GPU (Single NIC)**: `g5.12xlarge`, `g6.12xlarge`

### 2. Multi Network Interface Instances (use `add-cng-p5.yaml`)
High-performance instances with 16 or 32 EFA network interfaces. Required for:
- Large-scale distributed training (hundreds to thousands of GPUs)
- Maximum inter-node bandwidth and low latency
- Multi-node workloads requiring NVLink/NVSwitch

**Instance Types (P-Series):**
- `p5.48xlarge`: 8x NVIDIA H100 GPUs (32 EFA interfaces, 3.2 Tbps aggregate network bandwidth)
- `p5e.48xlarge`: 8x NVIDIA H200 GPUs (32 EFA interfaces, 3.2 Tbps aggregate network bandwidth)
- `p5en.48xlarge`: 8x NVIDIA H200 GPUs with NVSwitch (16 EFA interfaces, 3.2 Tbps aggregate network bandwidth)
- `p6-b200.48xlarge`: 8x NVIDIA B200 GPUs (32 EFA interfaces)

**Purchase Options:**
- On-Demand Capacity Reservations (ODCR): Reserved capacity with on-demand flexibility:
  - Guaranteed capacity in specific AZ
  - No long-term commitment
  - Pay on-demand rates when using reserved capacity
- Capacity Blocks for ML: Time-bound GPU capacity reservations for P5/P6 instances:
  - Ideal for scheduled large-scale training
  - Requires advance purchase
  - Use `add-cng-p5.yaml` with `CapacityReservationId` parameter

---

## Custom DLAMI Components

The custom DLAMI built by `pcs-ready-dlami-with-enroot-pyxis.yaml` adds container runtime support to PCS-ready DLAMI:

| Component | Version | Purpose |
|-----------|---------|---------|
| **Base Image** | PCS-ready DLAMI (Ubuntu 24.04 x86_64) | Pre-installed NVIDIA drivers, CUDA, PCS Agent, and Slurm |
| **Enroot** | 3.5.0 | Unprivileged container runtime |
| **Pyxis** | 0.20.0 | Slurm plugin for container jobs |

**What's already included in PCS-ready DLAMI:**
- AWS PCS Agent for node lifecycle management
- Slurm 25.05 and 25.11 (both versions available at `/opt/aws/pcs/scheduler/slurm-*`)
- NVIDIA drivers and CUDA toolkit
- SSM Agent for remote management

---

## Usage Examples

### Example 1: Basic CPU Cluster

```bash
aws cloudformation create-stack \
  --stack-name cpu-cluster \
  --template-url https://awsome-distributed-ai.s3.amazonaws.com/templates/pcs-ml-cluster-deploy-all.yaml \
  --parameters \
    ParameterKey=PrimarySubnetAZ,ParameterValue=us-east-1a \
    ParameterKey=ComputeNodeInstanceType,ParameterValue=c6i.4xlarge \
  --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM
```

### Example 2: GPU Cluster with GG Instances (Single NIC)

```bash
aws cloudformation create-stack \
  --stack-name gpu-cluster \
  --template-url https://awsome-distributed-ai.s3.amazonaws.com/templates/pcs-ml-cluster-deploy-all.yaml \
  --parameters \
    ParameterKey=PrimarySubnetAZ,ParameterValue=us-east-1a \
    ParameterKey=DeployOnDemandCNG,ParameterValue=true \
    ParameterKey=OnDemandCngName,ParameterValue=gpu-g6 \
    ParameterKey=OnDemandQueueName,ParameterValue=gpu-g6 \
    ParameterKey=OnDemandInstanceType,ParameterValue=g6.xlarge \
    ParameterKey=OnDemandMaxCount,ParameterValue=16 \
  --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM
```

### Example 3: P5 On-Demand Capacity Reservation (ODCR) Cluster (Multi NIC, Static)

```bash
aws cloudformation create-stack \
  --stack-name p5-cluster \
  --template-url https://awsome-distributed-ai.s3.amazonaws.com/templates/pcs-ml-cluster-deploy-all.yaml \
  --parameters \
    ParameterKey=PrimarySubnetAZ,ParameterValue=us-east-1a \
    ParameterKey=DeployPseriesCNG,ParameterValue=true \
    ParameterKey=PseriesCngName,ParameterValue=p5-odcr \
    ParameterKey=PseriesQueueName,ParameterValue=p5 \
    ParameterKey=PseriesInstanceType,ParameterValue=p5.48xlarge \
    ParameterKey=NetworkInterfaceCount,ParameterValue=32 \
    ParameterKey=PseriesMinCount,ParameterValue=4 \
    ParameterKey=PseriesMaxCount,ParameterValue=4 \
  --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM
```

### Example 4: P5 Cluster with Capacity Blocks for ML (Multi NIC, Static)

```bash
# First, purchase a capacity blocks for ml and get the reservation ID
CAPACITY_RESERVATION_ID="cr-0a1b2c3d4e5f6g7h8"

aws cloudformation create-stack \
  --stack-name p5-cluster \
  --template-url https://awsome-distributed-ai.s3.amazonaws.com/templates/pcs-ml-cluster-deploy-all.yaml \
  --parameters \
    ParameterKey=PrimarySubnetAZ,ParameterValue=us-east-1a \
    ParameterKey=DeployPseriesCNG,ParameterValue=true \
    ParameterKey=PseriesCngName,ParameterValue=p5-cb \
    ParameterKey=PseriesQueueName,ParameterValue=p5 \
    ParameterKey=PseriesInstanceType,ParameterValue=p5.48xlarge \
    ParameterKey=NetworkInterfaceCount,ParameterValue=32 \
    ParameterKey=PseriesMinCount,ParameterValue=4 \
    ParameterKey=PseriesMaxCount,ParameterValue=4 \
    ParameterKey=CapacityReservationId,ParameterValue=${CAPACITY_RESERVATION_ID} \
  --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM
```

---

## Accessing the Cluster

After deployment completes, connect to the login node using AWS Systems Manager Session Manager.

### Connect via Session Manager

1. **Get the EC2 Console URL** from the CloudFormation stack outputs:
   ```bash
   aws cloudformation describe-stacks \
     --stack-name pcs-ml-cluster \
     --query 'Stacks[0].Outputs[?OutputKey==`Ec2ConsoleUrl`].OutputValue' \
     --output text
   ```

2. **Open the URL in your browser** - This will take you to the EC2 console filtered to show only the login node instances.

3. **Connect to the login node**:
   - Select the login node instance
   - Click **Connect** button
   - Choose **Session Manager** tab
   - Click **Connect**

4. **Switch to the default user** (ubuntu for Ubuntu AMI, ec2-user for Amazon Linux):
   ```bash
   sudo su - ubuntu
   ```

5. **Verify cluster access**:
   ```bash
   sinfo                    # View cluster partitions and nodes
   squeue                   # View job queue
   scontrol show nodes      # Show detailed node information
   ```

### Alternative: AWS CLI

Connect directly using the AWS CLI:

**Note**: This method requires IAM permissions for `ec2:DescribeInstances` and `ssm:StartSession`. Alternatively, use AWS CloudShell which has these permissions pre-configured.

```bash
# Get the instance ID of the login node
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:aws:pcs:compute-node-group-name,Values=login" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

# Start a Session Manager session
aws ssm start-session --target $INSTANCE_ID
```

For more details, see the [Connect to Cluster](https://catalog.workshops.aws/ml-on-pcs/en-US/03-cluster/02-connect-cluster) section in the workshop.

---

## User Management and Observability

### LDAP User Management

For centralized user management across the cluster, see:
- [LDAP Server Setup Guide](../6.ldap_server/README.md) - Deploy and configure OpenLDAP for cluster-wide user authentication

### Observability Stack

For monitoring and observability, see:
- [Prometheus & Grafana Setup](../../4.validation_and_observability/4.prometheus-grafana/README.md) - Deploy monitoring stack with DCGM metrics

---

## Cleanup

To delete the entire cluster:

```bash
aws cloudformation delete-stack --stack-name pcs-ml-cluster
```

**Note**: Nested stacks will be deleted automatically. Manual backups of data in FSx filesystems are recommended before deletion.

---

## Additional Resources

- [AWS Parallel Computing Service Documentation](https://docs.aws.amazon.com/pcs/)
- [AI/ML for AWS PCS Workshop](https://catalog.workshops.aws/ml-on-pcs/)
- [Slurm Documentation](https://slurm.schedmd.com/documentation.html)
- [Enroot Documentation](https://github.com/NVIDIA/enroot)
- [Pyxis Documentation](https://github.com/NVIDIA/pyxis)
- [Capacity Blocks for ML](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-capacity-blocks.html)
