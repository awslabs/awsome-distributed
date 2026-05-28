# ML Training Reference Architectures & Tests <!-- omit from toc -->

This repository contains reference architectures and test cases for distributed model training with [Amazon SageMaker HyperPod](https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod.html), [AWS ParallelCluster](https://docs.aws.amazon.com/parallelcluster/latest/ug/what-is-aws-parallelcluster.html), [AWS Parallel Computing Service (PCS)](https://aws.amazon.com/pcs/), [AWS Batch](https://docs.aws.amazon.com/batch/latest/userguide/what-is-batch.html), and [Amazon EKS](https://docs.aws.amazon.com/eks/latest/userguide/getting-started-console.html). The test cases cover different types and sizes of models as well as different frameworks and parallel optimizations (PyTorch DDP/FSDP, Megatron-LM, NeMo...).

The major components of this directory are:

```
├── 1.architectures/               # CloudFormation templates for reference architectures
├── 2.ami_and_containers/          # Scripts to create AMIs and container images
├── 3.test_cases/                  # Reference test cases and/or benchmark scripts
├── 4.validation_and_observability/# Tools to measure performance or troubleshoot
└── micro-benchmarks/              # Micro-benchmarks (NCCL, NCCOM, NVSHMEM, etc.)
```

**NOTE**: The architectures are designed to work with the S3 bucket and VPC created using reference templates `1.architectures/0.common/` and `1.architectures/1.vpc_network/`. _You're strongly recommended to deploy these two templates **before** deploying any of the reference architectures._

## 0. Workshops

You can follow the workshops below to train models on AWS. Each contains examples for several test cases as well as nuggets of information on operating a cluster for LLM training.

| Name                                                                               | Comments                                                        |
| ---------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| [AI on SageMaker HyperPod](https://awslabs.github.io/ai-on-sagemaker-hyperpod/)   | Workshop for SageMaker HyperPod, shows how to deploy and monitor it |
| [AWS ParallelCluster](https://catalog.workshops.aws/ml-on-aws-parallelcluster)     | Similar workshop as HyperPod but on ParallelCluster             |
| [AWS Parallel Computing Service](https://catalog.workshops.aws/ml-on-pcs)     | Similar workshop as HyperPod but on AWS Parallel Computing Service             |

## Blog

Posts about distributed ML training on AWS are published at <https://awslabs.github.io/awsome-distributed/>. The Hugo source lives on the [`content`](https://github.com/awslabs/awsome-distributed/tree/content) branch.

Blog content is editorially curated by AWS authors. Code samples in this repo (`1.architectures/`, `3.test_cases/`, etc.) accept external contributions as usual — see [CONTRIBUTING.md](./CONTRIBUTING.md).

## 1. Architectures

Architectures are located in `1.architectures` and consist of utilities and service-related architectures.

| Name                                                                           | Category | Usage                                                |
| ------------------------------------------------------------------------------ | -------- | ---------------------------------------------------- |
| [`0.common`](./1.architectures/0.common)                                       | Storage  | Common resources (S3 bucket, event notifications)    |
| [`1.vpc_network`](./1.architectures/1.vpc_network)                             | Network  | Create a VPC with subnets and required resources     |
| [`2.aws-parallelcluster`](./1.architectures/2.aws-parallelcluster)             | Compute  | Cluster templates for GPU & custom silicon training  |
| [`3.aws-batch`](./1.architectures/3.aws-batch)                                 | Compute  | AWS Batch template for distributed training          |
| [`4.amazon-eks`](./1.architectures/4.amazon-eks)                               | Compute  | Manifest files to train with Amazon EKS              |
| [`5.sagemaker-hyperpod`](./1.architectures/5.sagemaker-hyperpod)               | Compute  | SageMaker HyperPod template for distributed training |
| [`6.ldap_server`](./1.architectures/6.ldap_server)                             | Identity | LDAP server for multi-user cluster access            |
| [`7.sagemaker-hyperpod-eks`](./1.architectures/7.sagemaker-hyperpod-eks)       | Compute  | SageMaker HyperPod with EKS orchestration            |
| [`8.accounting-database`](./1.architectures/8.accounting-database)             | Tooling  | Accounting database for job tracking                 |
| [`aws-pcs`](./architectures/aws-pcs)                                           | Compute  | AWS Parallel Computing Service templates with Slurm scheduler |

You will also find [documentation](./1.architectures/efa-cheatsheet.md) for EFA and the recommended environment variables.

## 2. Custom Amazon Machine Images

Custom machine images can be built using [Packer](https://www.packer.io) for AWS ParallelCluster, Amazon EKS and plain EC2. These images are based on Ansible roles and playbooks.

## 3. Test Cases

Test cases are organized under `3.test_cases/` by framework (e.g. `pytorch/`, `megatron/`, `jax/`). Within each framework, directories are named after the training library or method (e.g. `picotron/`, `FSDP/`, `megatron-lm/`).

Each test case follows this general structure:

```
3.test_cases/
└── <framework>/                # e.g. pytorch, megatron, jax
    └── <library>/              # e.g. picotron, FSDP, megatron-lm
        └── <model>/            # e.g. SmolLM-1.7B (may be omitted for single-model cases)
            ├── Dockerfile      # Container / environment setup
            ├── README.md
            ├── slurm/          # Slurm-specific launch scripts
            ├── kubernetes/     # Kubernetes manifests
            └── hyperpod-eks/   # HyperPod EKS instructions
```

The top-level directory for each test case contains general introduction and environment setup (Dockerfiles, training scripts, configs), while subdirectories provide service-specific launch instructions.

Browse [`3.test_cases/`](./3.test_cases) to see the full list of available frameworks and test cases.

## 4. Validation and Observability

Utility scripts and tools for validating your environment and monitoring training jobs are under `4.validation_and_observability/`.

| Name                                                                                            | Comments                                                        |
| ----------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| [`1.pytorch-env-validation`](./4.validation_and_observability/1.pytorch-env-validation)         | Validates your PyTorch environment                              |
| [`2.gpu-cluster-healthcheck`](./4.validation_and_observability/2.gpu-cluster-healthcheck)       | GPU cluster health checks                                       |
| [`3.efa-node-exporter`](./4.validation_and_observability/3.efa-node-exporter)                   | Node exporter with Amazon EFA monitoring modules                |
| [`4.prometheus-grafana`](./4.validation_and_observability/4.prometheus-grafana)                  | Monitoring for SageMaker HyperPod and EKS GPU clusters          |
| [`5.nsight`](./4.validation_and_observability/5.nsight)                                         | Shows how to run Nvidia Nsight Systems to profile your workload |

## 5. Micro-benchmarks

Micro-benchmarks for evaluating network and communication performance are under `micro-benchmarks/`.

| Name                                                                  | Comments                                      |
| --------------------------------------------------------------------- | --------------------------------------------- |
| [`nccl-tests`](./micro-benchmarks/nccl-tests)                         | NCCL collective communication benchmarks      |
| [`nccom-tests`](./micro-benchmarks/nccom-tests)                       | NCCOM communication benchmarks                |
| [`nvshmem`](./micro-benchmarks/nvshmem)                               | NVSHMEM benchmarks                            |
| [`expert-parallelism`](./micro-benchmarks/expert-parallelism)         | Expert parallelism (MoE) benchmarks           |

## 6. Contributors

Thanks to all the contributors for building, reviewing and testing.

[![Contributors](https://contrib.rocks/image?repo=awslabs/awsome-distributed)](https://github.com/awslabs/awsome-distributed/graphs/contributors)

## 7. Star History

[![Star History Chart](https://api.star-history.com/svg?repos=awslabs/awsome-distributed&type=Date)](https://star-history.com/#awslabs/awsome-distributed&Date)
