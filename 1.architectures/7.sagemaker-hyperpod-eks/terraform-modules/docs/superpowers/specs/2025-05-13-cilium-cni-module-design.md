# Cilium CNI Module for HyperPod EKS Terraform

**Date:** 2025-05-13
**Branch:** `hyperpod-eks-cilium-tf`
**Status:** Approved

## Goal

Enable users to replace the AWS VPC CNI with Cilium on HyperPod EKS clusters by setting `enable_cilium = true`. Support three pre-configured routing modes (overlay, ENI, chaining) plus a fully custom mode for new EKS deployments, and be compatible with existing EKS clusters that already have Cilium installed.

## Supported Modes

| Mode | `cilium_mode` | VPC CNI addon | Cilium role | Pod IP allocation |
|------|--------------|---------------|-------------|-------------------|
| Overlay (VXLAN) | `"overlay"` | Skipped | Full CNI + IPAM | Cluster-pool (non-VPC-routable) |
| ENI (native routing) | `"eni"` | Skipped | Full CNI + IPAM via AWS ENI | VPC-routable ENI IPs |
| CNI Chaining | `"chaining"` | Kept active | eBPF policy/LB/encryption only | VPC CNI handles IPAM |
| Custom | `"custom"` | Skipped | User-defined | User-defined |

### Mode trade-offs

- **Overlay:** Most pods per node (not bounded by ENI limits), but pod-to-VPC traffic is SNATed. Webhooks must be host-networked or exposed via Service/Ingress since the API server cannot route to overlay IPs.
- **ENI:** VPC-routable pod IPs (same as VPC CNI behavior), Cilium manages ENI allocation. Bounded by ENI/IP limits per instance type. IPv4 only.
- **Chaining:** Least disruptive (VPC CNI still does networking), but some Cilium features limited (L7 policy, IPsec encryption).
- **Custom:** Full user control. No base defaults applied — `cilium_helm_values` is the entire Helm configuration. User is responsible for providing a valid Cilium config. VPC CNI is skipped by default (user can override via `cilium_skip_vpc_cni = false` if they need chaining semantics).

## New Variable Surface (root `variables.tf`)

```hcl
variable "enable_cilium" {
  description = "Enable Cilium CNI. When true and creating a new EKS cluster, replaces or chains with the VPC CNI based on cilium_mode."
  type        = bool
  default     = false
}

variable "cilium_mode" {
  description = "Cilium operating mode: overlay (VXLAN tunnel), eni (native ENI routing), chaining (policy-only on top of VPC CNI), or custom (user provides all Helm values)."
  type        = string
  default     = "overlay"
  validation {
    condition     = contains(["overlay", "eni", "chaining", "custom"], var.cilium_mode)
    error_message = "cilium_mode must be one of: overlay, eni, chaining, custom."
  }
}

variable "cilium_version" {
  description = "Cilium Helm chart version to deploy."
  type        = string
  default     = "1.19.4"
}

variable "cilium_helm_values" {
  description = "Custom Helm values merged on top of mode-specific defaults. In custom mode, this IS the entire config (no base defaults applied). For overlay/eni/chaining modes, these values override the base defaults."
  type        = any
  default     = {}
}
```

## Module Structure

### New: `modules/cilium/`

Files: `main.tf`, `variables.tf`, `outputs.tf`

#### `variables.tf`

Inputs:
- `eks_cluster_name` (string)
- `eks_cluster_endpoint` (string)
- `eks_cluster_certificate_authority` (string, sensitive)
- `cilium_mode` (string)
- `cilium_version` (string)
- `cilium_helm_values` (any)
- `node_role_arn` (string) — for ENI mode IAM policy attachment

#### `main.tf`

1. **Locals** — compute mode-specific Helm values:

```hcl
locals {
  overlay_values = {
    routingMode    = "tunnel"
    tunnelProtocol = "vxlan"
    ipam = {
      mode = "cluster-pool"
    }
  }

  eni_values = {
    eni = {
      enabled = true
    }
    ipam = {
      mode = "eni"
    }
    routingMode          = "native"
    enableIPv4Masquerade = false
  }

  chaining_values = {
    cni = {
      chainingMode = "aws-cni"
      exclusive    = false
    }
    enableIPv4Masquerade = false
    routingMode          = "native"
  }

  base_values = {
    overlay  = local.overlay_values
    eni      = local.eni_values
    chaining = local.chaining_values
    custom   = {}
  }

  # Merge: user values override base values. In custom mode, base is empty so user values are the entire config.
  effective_values = merge(local.base_values[var.cilium_mode], var.cilium_helm_values)
}
```

2. **Helm release:**

```hcl
resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = var.cilium_version
  namespace  = "kube-system"

  values = [yamlencode(local.effective_values)]

  wait          = true
  wait_for_jobs = true
  timeout       = 600
}
```

3. **IAM policy for ENI mode** (conditional):

```hcl
resource "aws_iam_role_policy" "cilium_eni" {
  count = var.cilium_mode == "eni" ? 1 : 0
  name  = "cilium-eni-policy"
  role  = var.node_role_arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ec2:CreateNetworkInterface",
        "ec2:AttachNetworkInterface",
        "ec2:DeleteNetworkInterface",
        "ec2:DescribeNetworkInterfaces",
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeSubnets",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeVpcs",
        "ec2:AssignPrivateIpAddresses",
        "ec2:UnassignPrivateIpAddresses",
        "ec2:ModifyNetworkInterfaceAttribute",
      ]
      Resource = "*"
    }]
  })
}
```

#### `outputs.tf`

- `cilium_release_name`
- `cilium_release_namespace`
- `cilium_mode`

### Modified: `modules/eks_cluster/main.tf`

Add `var.skip_vpc_cni` input. Conditionally skip the VPC CNI addon:

```hcl
resource "aws_eks_addon" "vpc_cni" {
  count                       = var.skip_vpc_cni ? 0 : 1
  cluster_name                = aws_eks_cluster.cluster.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}
```

New variable in `modules/eks_cluster/variables.tf`:
```hcl
variable "skip_vpc_cni" {
  description = "Skip deploying the VPC CNI EKS addon (used when Cilium replaces VPC CNI)."
  type        = bool
  default     = false
}
```

### Modified: `modules/security_group/main.tf`

Add conditional VXLAN rule for overlay mode:

```hcl
resource "aws_vpc_security_group_ingress_rule" "vxlan" {
  count             = var.enable_vxlan_rule ? 1 : 0
  security_group_id = local.security_group_id
  referenced_security_group_id = local.security_group_id
  ip_protocol       = "udp"
  from_port         = 8472
  to_port           = 8472
  description       = "Cilium VXLAN overlay"
}

resource "aws_vpc_security_group_egress_rule" "vxlan" {
  count             = var.enable_vxlan_rule ? 1 : 0
  security_group_id = local.security_group_id
  referenced_security_group_id = local.security_group_id
  ip_protocol       = "udp"
  from_port         = 8472
  to_port           = 8472
  description       = "Cilium VXLAN overlay"
}
```

New variable in `modules/security_group/variables.tf`:
```hcl
variable "enable_vxlan_rule" {
  description = "Add UDP 8472 intra-SG rule for Cilium VXLAN overlay mode."
  type        = bool
  default     = false
}
```

### Modified: Root `main.tf`

```hcl
locals {
  # Skip VPC CNI when Cilium replaces it (overlay, ENI, or custom mode) on new clusters.
  # Chaining mode keeps VPC CNI active since Cilium only adds eBPF on top.
  skip_vpc_cni = var.enable_cilium && var.cilium_mode != "chaining"

  # Deploy Cilium module only when creating a new cluster with Cilium enabled
  create_cilium = var.enable_cilium && var.create_eks_module
}

module "security_group" {
  # ... existing params ...
  enable_vxlan_rule = var.enable_cilium && var.cilium_mode == "overlay"
}

module "eks_cluster" {
  # ... existing params ...
  skip_vpc_cni = local.skip_vpc_cni
}

module "cilium" {
  source = "./modules/cilium"
  count  = local.create_cilium ? 1 : 0

  eks_cluster_name                  = module.eks_cluster[0].cluster_name
  eks_cluster_endpoint              = module.eks_cluster[0].cluster_endpoint
  eks_cluster_certificate_authority = module.eks_cluster[0].cluster_certificate_authority
  cilium_mode                       = var.cilium_mode
  cilium_version                    = var.cilium_version
  cilium_helm_values                = var.cilium_helm_values
  node_role_arn                     = module.eks_cluster[0].node_role_arn

  depends_on = [module.eks_cluster]
}

module "helm_chart" {
  # ... existing params ...
  depends_on = [module.eks_cluster, module.cilium]  # Added cilium dependency
}
```

## Existing Cluster Path

When `create_eks_module = false` (user brings their own EKS cluster with Cilium already installed):

- `local.create_cilium = false` — Cilium module is NOT deployed
- Security group module still receives `enable_vxlan_rule` so users can add the VXLAN rule to their existing SG if needed
- VPC CNI skip is moot (we didn't create the EKS addon)
- HyperPod components deploy normally — they just need a functional CNI, which Cilium provides

The user sets `enable_cilium = true` primarily as a signal that their cluster uses Cilium, which triggers appropriate SG rules and skips any VPC-CNI-specific assumptions.

## Dependency Graph

```
vpc → private_subnet → security_group → vpc_endpoints
                                      ↘
                          eks_cluster → cilium → helm_chart → hyperpod_cluster → [addons]
```

## Constraints and Gotchas

1. **Closed network incompatibility:** Overlay mode requires pulling Cilium images from quay.io. In closed-network deployments, images must be pre-staged to ECR. The existing `tools/copy-images-to-ecr.sh` pattern can be extended, but this is out of initial scope. We should document this limitation.

2. **RIG mode:** RIG already disables many features. Cilium should be compatible with RIG since it only affects HyperPod-level features, not cluster networking. No special handling needed.

3. **Node taints:** For overlay and ENI modes on new clusters, nodes should ideally have `node.cilium.io/agent-not-ready=true:NoExecute` to prevent scheduling before Cilium is ready. This is handled by the Cilium DaemonSet itself (it removes the taint once ready), but only if the EKS managed node group has the taint set. Since HyperPod manages its own instance groups, and those instances join after Cilium is deployed via Helm, this should not be an issue — Cilium will already be running when HyperPod nodes join.

4. **CoreDNS dependency:** CoreDNS needs a functioning CNI. Currently it's deployed via `null_resource` in the EKS module. With Cilium, CoreDNS should come up after Cilium is healthy. The existing approach (deploying CoreDNS addon separately with `--resolve-conflicts OVERWRITE`) should work since Cilium deploys with `wait = true`.

5. **Helm provider auth:** The cilium module uses `helm_release` which relies on the same Kubernetes/Helm provider config already set up in `providers.tf`. No additional provider config needed.

6. **ENI mode IAM:** The policy attachment targets the EKS node role. The EKS module needs to expose `node_role_arn` as an output (if not already).

## Out of Scope (initial implementation)

- Hubble observability stack (users can enable via `cilium_helm_values`)
- ClusterMesh multi-cluster
- Cilium network policies (users manage these themselves)
- Closed-network image staging for Cilium
- Automated migration from VPC CNI to Cilium on existing clusters
- Cilium Gateway API / Ingress controller
