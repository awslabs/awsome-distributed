# AGENTS.md

## Repository Overview

Multi-architecture reference repo for distributed ML training on AWS (SageMaker HyperPod, ParallelCluster, Batch, EKS). Each subdirectory under `1.architectures/` is largely self-contained.

## Active Work Area: Terraform Modules

Path: `1.architectures/7.sagemaker-hyperpod-eks/terraform-modules/hyperpod-eks-tf/`

This Terraform stack deploys a SageMaker HyperPod cluster on EKS. The EKS control plane is a prerequisite for HyperPod — it is NOT an independent EKS deployment. All features must be compatible with HyperPod's SageMaker-managed instances.

### Terraform Conventions

- **Terraform >= 1.14.0** required (see `versions.tf` for full provider constraints)
- Module naming: `snake_case` directories under `modules/`
- Every module has: `main.tf`, `variables.tf`, `outputs.tf` (minimum)
- Split additional resource types into named files (e.g., `iam_roles.tf`, `vpc_endpoints.tf`)
- Conditional creation at root level: `count = var.create_<module>_module ? 1 : 0`
- Resource naming: `"${var.resource_name_prefix}-SMHP-<ResourceType>"`
- All variables require `description` and `type`; complex types use `object()` with `optional()`
- Feature flags: `create_<module>_module` (bool) — infrastructure defaults `true`, addons default `false`
- Existing resource inputs: `existing_<resource>_id` / `existing_<resource>_name`
- Input validation via `validation { condition = ..., error_message = ... }` blocks
- Uses both `aws` and `awscc` providers (awscc for SageMaker cluster resources)
- Helm chart revisions pinned to git commit SHAs, not tags

### Commands

```bash
# From hyperpod-eks-tf/ directory:
terraform init
terraform plan -var-file="custom.tfvars"
terraform apply -var-file="custom.tfvars"

# Format check (not automated in CI but expected):
terraform fmt -recursive

# Validate:
terraform validate
```

### Key Files

- `variables.tf` — all input variables (~900 lines), the source of truth for configuration surface
- `main.tf` — orchestration with explicit `depends_on` between modules
- `providers.tf` — aws, awscc, helm, kubernetes, grafana provider configs
- `custom.tfvars` / `closed-network.tfvars` / `rig_custom.tfvars` — environment-specific var files (gitignored patterns)
- `.gitignore` — ignores `.terraform/`, `*.tfstate*`, `.terraform.lock.hcl`, `env_vars.sh`, `terraform_outputs.json`, `docs/`

### Module Dependency Order

```
vpc → private_subnet → security_group → eks_cluster → cilium → helm_chart → hyperpod_cluster → fsx_lustre
```

### Gotchas

- `.terraform.lock.hcl` is gitignored — provider locks are not committed
- `local.rig_mode` auto-disables incompatible features when RIG (restricted instance groups) are configured
- Some operations use `null_resource` + `local-exec` as workarounds for missing provider support
- No Terraform tests exist (no terratest, no `terraform test`) — validate manually
- `fsx_lustre` unconditionally references `module.hyperpod_cluster[0].primary_subnet_id` — must pass `create_fsx_module=false` if you disable HyperPod (`create_hyperpod_module=false`)
- `helm_chart` module requires `/tmp/helm-repo` to contain a clone of `https://github.com/aws/sagemaker-hyperpod-cli.git`
- `helm_release.cilium` uses `wait = false` because Cilium DaemonSet can't schedule until HyperPod nodes join (chicken-and-egg)

### HyperPod Platform Constraints

HyperPod instances are SageMaker-managed and have these implications:
- **Not visible in EC2 API** — `ec2:DescribeInstances` cannot find them. Any feature requiring EC2 instance discovery will fail.
- **Cilium ENI mode incompatible** — removed from this stack. Only `overlay`, `chaining`, and `custom` modes are supported.
- **Node identity** — nodes register as `hyperpod-i-<instance-id>` but the instance ID is internal to SageMaker.

### Cilium CNI Module

Path: `modules/cilium/`

Modes: `overlay` (VXLAN tunnel), `chaining` (VPC CNI + Cilium policy), `custom` (user provides all values)

Key design decisions:
- `skip_vpc_cni` local in root `main.tf` conditionally removes the VPC CNI EKS addon when mode != "chaining"
- `enable_vxlan_rule` in security_group module adds UDP 8472 rules only for overlay mode
- Helm chart from `https://helm.cilium.io/`, version pinned via `cilium_version` variable (default `1.19.4`)

## Repo-Wide Conventions

- **External dependencies must pin versions** (commit SHA or tag, never `latest`)
- **Scripts numbered sequentially** starting at 0: `0.preprocessing.sh`, `1.processing.sh`, ...
- **Each asset self-contained** with its own README, prerequisites, and copy-pasteable commands
- **Infrastructure as Code:** CloudFormation, CDK, or Terraform only
- **Git LFS required** for `.gif`, `.zip`, `.tar.bz2`, `.tar.gz` files
- **EditorConfig:** LF endings, UTF-8, trim trailing whitespace, indent 2 for YAML/JSON
- **Markdown lint:** line length 100 (code blocks exempt), inline HTML allowed, no first-line heading rule

## CI / PR Process

- PRs target `main` branch; `content` branch is AWS-internal blog content (auto-closes external PRs)
- Static analysis on PRs: pylint, flake8, bandit, semgrep (Python code only)
- No Terraform-specific CI validation currently

## Commit Style

Mixed but trending conventional: `type(scope): description (#PR)` — e.g., `fix(healthcheck): ...`, `chore: ...`, `docs: ...`
