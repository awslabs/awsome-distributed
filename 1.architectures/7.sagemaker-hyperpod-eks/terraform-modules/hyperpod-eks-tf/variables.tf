variable "resource_name_prefix" {
  description = "Prefix to be used for all resources"
  type        = string
  default     = "sagemaker-hyperpod-eks"
}

variable "aws_region" {
  description = "AWS Region to be targeted for deployment"
  type        = string
  default     = "us-west-2"
}

# VPC Module Variables
variable "create_vpc_module" {
  description = "Whether to create VPC module"
  type        = bool
  default     = true
}

variable "closed_network" {
  description = "Whether to deploy in closed network mode (no internet gateway, NAT gateway, or public subnets)"
  type        = bool
  default     = false
}

variable "vpc_cidr" {
  description = "The IP range (CIDR notation) for the VPC"
  type        = string
  default     = "10.192.0.0/16"
}

variable "public_subnet_1_cidr" {
  description = "The IP range (CIDR notation) for the public subnet in the first Availability Zone"
  type        = string
  default     = "10.192.10.0/24"
}

variable "public_subnet_2_cidr" {
  description = "The IP range (CIDR notation) for the public subnet in the second Availability Zone"
  type        = string
  default     = "10.192.11.0/24"
}

variable "existing_vpc_id" {
  description = "The ID of an existing VPC to use if not creating a new one"
  type        = string
  default     = ""
}

# Private Subnet Module Variables
variable "create_private_subnet_module" {
  description = "Whether to create private subnet module"
  type        = bool
  default     = true
}

variable "private_subnet_cidrs" {
  description = "List of CIDR blocks for HyperPod private subnets (up to 5 AZs)"
  type        = list(string)
  default     = ["10.1.0.0/16", "10.2.0.0/16", "10.3.0.0/16", "10.4.0.0/16"]
}

variable "existing_nat_gateway_id" {
  description = "The ID of an existing NAT Gateway"
  type        = string
  default     = ""
}

variable "existing_private_subnet_ids" {
  description = "List of existing private subnet IDs"
  type        = list(string)
  default     = []
}

# Security Group Module Variables
variable "create_security_group_module" {
  description = "Whether to create security group module"
  type        = bool
  default     = true
}

variable "existing_security_group_id" {
  description = "The ID of an existing security group"
  type        = string
  default     = ""
}

variable "create_vpc_endpoint_ingress_rule" {
  description = "Whether to create HTTPS ingress rule from VPC CIDR for VPC endpoints (recommended for closed networks)"
  type        = bool
  default     = true
}

# EKS Cluster Module Variables
variable "create_eks_module" {
  description = "Whether to create EKS cluster module"
  type        = bool
  default     = true
}

variable "kubernetes_version" {
  description = "The Kubernetes version to use for the EKS cluster"
  type        = string
  default     = "1.33"
}

variable "eks_cluster_name" {
  description = "The name of the EKS cluster"
  type        = string
  default     = "sagemaker-hyperpod-eks-cluster"
}

variable "existing_eks_cluster_name" {
  description = "The name of an existing EKS cluster"
  type        = string
  default     = ""
}

variable "create_eks_subnets" {
  description = "Whether to create new subnets for EKS or use existing ones (only applies when create_eks_module is true)"
  type        = bool
  default     = true
}

variable "existing_eks_subnet_ids" {
  description = "List of existing subnet IDs to use for EKS (only used when create_eks_module is true and create_eks_subnets is false)"
  type        = list(string)
  default     = []
}

variable "eks_private_subnet_1_cidr" {
  description = "The IP range (CIDR notation) for the first EKS private subnet (only used when create_eks_subnets is true)"
  type        = string
  default     = "10.192.7.0/28"
}

variable "eks_private_subnet_2_cidr" {
  description = "The IP range (CIDR notation) for the second EKS private subnet (only used when create_eks_subnets is true)"
  type        = string
  default     = "10.192.8.0/28"
}

# S3 Bucket Module Variables
variable "create_s3_bucket_module" {
  description = "Whether to create S3 bucket module"
  type        = bool
  default     = true
}

variable "existing_s3_bucket_name" {
  description = "The name of an existing S3 bucket"
  type        = string
  default     = ""
}

# S3 Endpoint Module Variables
variable "create_vpc_endpoints_module" {
  description = "Whether to create VPC endpoints module"
  type        = bool
  default     = true
}

variable "existing_private_route_table_ids" {
  description = "List of existing private route table IDs"
  type        = list(string)
  default     = []
}

# Closed Network - VPC Endpoint Configuration
variable "create_s3_endpoint" {
  description = "Create S3 gateway endpoint (required for container images and data access)"
  type        = bool
  default     = true
}

# Closed Network - EKS Endpoint Access Configuration
variable "eks_endpoint_private_access" {
  description = "Enable private API server endpoint (required for closed networks)"
  type        = bool
  default     = true
}

variable "eks_endpoint_public_access" {
  description = "Enable public API server endpoint (should be false for closed networks)"
  type        = bool
  default     = true
}

variable "create_ec2_endpoint" {
  description = "Create EC2 interface endpoint (CRITICAL in closed networks - required for AWS CNI plugin to assign IPs to pods)"
  type        = bool
  default     = false
}

variable "create_ecr_api_endpoint" {
  description = "Create ECR API interface endpoint (required for ECR authentication in closed networks)"
  type        = bool
  default     = false
}

variable "create_ecr_dkr_endpoint" {
  description = "Create ECR DKR interface endpoint (required for pulling container images from ECR in closed networks)"
  type        = bool
  default     = false
}

variable "create_sts_endpoint" {
  description = "Create STS interface endpoint (required for IAM role assumption in closed networks)"
  type        = bool
  default     = false
}

variable "create_logs_endpoint" {
  description = "Create CloudWatch Logs interface endpoint (required for sending logs in closed networks)"
  type        = bool
  default     = false
}

variable "create_monitoring_endpoint" {
  description = "Create CloudWatch Monitoring interface endpoint (required for sending metrics in closed networks)"
  type        = bool
  default     = false
}

variable "create_ssm_endpoint" {
  description = "Create SSM interface endpoint (recommended for Systems Manager access in closed networks)"
  type        = bool
  default     = false
}

variable "create_ssmmessages_endpoint" {
  description = "Create SSM Messages interface endpoint (recommended for Session Manager in closed networks)"
  type        = bool
  default     = false
}

variable "create_ec2messages_endpoint" {
  description = "Create EC2 Messages interface endpoint (recommended for SSM Agent communication in closed networks)"
  type        = bool
  default     = false
}

variable "create_eks_auth_endpoint" {
  description = "Create EKS Auth interface endpoint (CRITICAL in closed networks - required for EKS Pod Identity authentication)"
  type        = bool
  default     = false
}

# Lifecycle Script Module Variables
variable "create_lifecycle_script_module" {
  description = "Whether to create lifecycle script module"
  type        = bool
  default     = true
}

# SageMaker IAM Role Module Variables
variable "create_sagemaker_iam_role_module" {
  description = "Whether to create SageMaker IAM role module"
  type        = bool
  default     = true
}

variable "existing_sagemaker_iam_role_name" {
  description = "The name of an existing SageMaker IAM role"
  type        = string
  default     = ""
}

variable "rig_input_s3_bucket" {
  description = "The name of the RIG input S3 bucket"
  type        = string
  default     = null
}

variable "rig_output_s3_bucket" {
  description = "The name of the RIG output S3 bucket"
  type        = string
  default     = null
}

variable "gated_access" {
  description = "Whether to include gated access permissions"
  type        = bool
  default     = true
}

variable "rig_rft_lambda_access" {
  description = "Whether to include Lambda access permissions for RFT"
  type        = bool
  default     = true
}

variable "rig_rft_sqs_access" {
  description = "Whether to include SQS access permissions for RFT"
  type        = bool
  default     = true
}

# Helm Chart Module Variables
variable "create_helm_chart_module" {
  description = "Whether to create Helm chart module"
  type        = bool
  default     = true
}

variable "helm_repo_path" {
  description = "The path to the HyperPod Helm chart"
  type        = string
  default     = "helm_chart/HyperPodHelmChart"
}

variable "helm_repo_path_hpio" {
  description = "The path to the HyperPod Inference Operator Helm chart"
  type        = string
  default     = "helm_chart/HyperPodHelmChart/charts/inference-operator"
}

variable "helm_release_name" {
  description = "The name of the Helm release"
  type        = string
  default     = "hyperpod-dependencies"
}

variable "helm_release_name_hpio" {
  description = "The name of the Helm release for the HyperPod Inference Operator"
  type        = string
  default     = "hyperpod-inference-operator"
}

# Check GITHUB_REPO_REVISION here: https://github.com/aws/sagemaker-hyperpod-cluster-setup/blob/main/eks/cloudformation/helm-chart-template.yaml
variable "helm_repo_revision" {
  description = "Git revision for normal mode"
  type        = string
  default     = "9f496a6364759553f73ff534434a057ef4bdc004"
}

variable "helm_repo_revision_rig" {
  description = "Git revision for RIG mode"
  type        = string
  default     = "c5275ddbbca58164d1f5bd3a2811e0fc952f7ff4"
}

variable "namespace" {
  description = "The Kubernetes namespace"
  type        = string
  default     = "kube-system"
}

variable "enable_gpu_operator" {
  description = "Whether to enable the GPU operator"
  type        = bool
  default     = false
}

variable "enable_mlflow" {
  description = "Whether to enable the MLFlow"
  type        = bool
  default     = false
}

variable "enable_kubeflow_training_operators" {
  description = "Whether to enable the Kubeflow training operators"
  type        = bool
  default     = true
}

# task governance helm chart values
variable "enable_cluster_role_and_bindings" {
  description = "Whether to enable the cluster role and bindings"
  type        = bool
  default     = false
}

variable "enable_namespaced_role_and_bindings" {
  description = "Whether to enable the namespaced role and bindings"
  type        = bool
  default     = false
}

variable "enable_team_role_and_bindings" {
  description = "Whether to enable the team role and binding"
  type        = bool
  default     = false
}

variable "enable_nvidia_device_plugin" {
  description = "Whether to enable the NVIDIA device plugin"
  type        = bool
  default     = true
}

variable "enable_neuron_device_plugin" {
  description = "Whether to enable the Neuron device plugin"
  type        = bool
  default     = true
}

variable "enable_mpi_operator" {
  description = "Whether to enable the MPI operator"
  type        = bool
  default     = true
}

variable "enable_deep_health_check" {
  description = "Whether to enable the deep health check"
  type        = bool
  default     = true
}

variable "enable_job_auto_restart" {
  description = "Whether to enable the job auto restart"
  type        = bool
  default     = true
}

variable "enable_hyperpod_patching" {
  description = "Whether to enable the hyperpod patching"
  type        = bool
  default     = true
}

variable "rig_script_path" {
  description = "The path to the RIG script"
  type        = string
  default     = "helm_chart/install_rig_dependencies.sh"
}

# HyperPod Cluster Module Variables
variable "create_hyperpod_module" {
  description = "Whether to create HyperPod cluster module"
  type        = bool
  default     = true
}

variable "hyperpod_cluster_name" {
  description = "Name of the HyperPod cluster"
  type        = string
  default     = "ml-cluster"
}

variable "auto_node_recovery" {
  description = "Whether to enable or disable the automatic node recovery feature"
  type        = bool
  default     = true
}

variable "continuous_provisioning_mode" {
  description = "whether to enable continuous node provisioning mode"
  type        = bool
  default     = true
}

variable "karpenter_autoscaling" {
  description = "Whether to enable Karpenter autoscaling"
  type        = bool
  default     = false
}

variable "instance_groups" {
  description = "List of instance group configurations"
  type = list(object({
    name                      = string
    instance_type             = string
    instance_count            = number
    ebs_volume_size_in_gb     = number
    threads_per_core          = number
    enable_stress_check       = bool
    enable_connectivity_check = bool
    lifecycle_script          = string
    availability_zone_id      = string
    image_id                  = optional(string)
    training_plan_arn         = optional(string)
    labels                    = optional(map(string))
    taints = optional(list(object({
      key    = string
      value  = optional(string)
      effect = string
    })))
  }))
  default = []
}

variable "restricted_instance_groups" {
  description = "List of restricted instance group configurations"
  type = list(object({
    name                             = string
    instance_type                    = string
    instance_count                   = number
    ebs_volume_size_in_gb            = number
    threads_per_core                 = number
    enable_stress_check              = bool
    enable_connectivity_check        = bool
    fsxl_per_unit_storage_throughput = number
    fsxl_size_in_gi_b                = number
    availability_zone_id             = string
    training_plan_arn                = optional(string)
  }))
  default = []
}

# FSx for Lustre Module Variables
# FSxL CSI driver (required for for HPIO)
# If setting create_hyperpod_inference_operator_module = true 
# only set create_fsx_module = false if FSxL CSI driver was previously installed
variable "create_fsx_module" {
  description = "Whether to create FSx for Lustre module"
  type        = bool
  default     = true
}

variable "create_new_fsx_filesystem" {
  description = "Whether to create a new FSx filesystem via dynamic provisioning"
  type        = bool
  default     = false
}

variable "fsx_storage_capacity" {
  description = "Storage capacity for FSx filesystem in GiB"
  type        = number
  default     = 1200
}

variable "fsx_throughput" {
  description = "Per unit storage throughput for FSx filesystem"
  type        = number
  default     = 250
}

variable "fsx_data_compression_type" {
  description = "Data compression type for FSx filesystem"
  type        = string
  default     = "LZ4"
  validation {
    condition     = contains(["NONE", "LZ4"], var.fsx_data_compression_type)
    error_message = "Data compression type must be NONE or LZ4."
  }
}

variable "fsx_file_system_type_version" {
  description = "File system type version for FSx filesystem"
  type        = string
  default     = "2.15"
}

variable "create_fsx_pvc_namespace" {
  description = "Create the namespace for FSx PVC (set to false if namespace already exists)"
  type        = bool
  default     = true
}

variable "fsx_pvc_namespace" {
  description = "Namespace for FSx PVC"
  type        = string
  default     = "default"
}


# Observability Module Variables
variable "create_observability_module" {
  description = "Whether to create observability module"
  type        = bool
  default     = false
}

# AMP variables
variable "create_prometheus_workspace" {
  description = "Specify whether to create a new Amazon Managed Service for Prometheus (AMP) workspace"
  type        = bool
  default     = true
}

variable "existing_prometheus_workspace_id" {
  description = "The ID of the existing Amazon Managed Service for Prometheus (AMP) workspace"
  type        = string
  default     = ""
}

variable "prometheus_workspace_name" {
  description = "(Optional) Name of the new Amazon Managed Service for Prometheus (AMP) workspace"
  type        = string
  default     = ""
}

# AMG variables
variable "create_grafana_workspace" {
  description = "Specify whether to create a new Amazon Managed Grafana (AMG) workspace"
  type        = bool
  default     = true
}

variable "existing_grafana_workspace_id" {
  description = "The ID of the existing Amazon Managed Grafana (AMG) workspace"
  type        = string
  default     = ""
}

variable "grafana_workspace_name" {
  description = "(Optional) Name of the new Amazon Managed Grafana (AMG) workspace"
  type        = string
  default     = ""
}

# Metrics levels
variable "training_metric_level" {
  description = "Level of training metrics"
  type        = string
  default     = "BASIC"
  validation {
    condition     = contains(["BASIC", "ADVANCED"], var.training_metric_level)
    error_message = "Training metric level must be one of: BASIC, ADVANCED."
  }
}

variable "task_governance_metric_level" {
  description = "Level of task governance metrics"
  type        = string
  default     = "DISABLED"
  validation {
    condition     = contains(["DISABLED", "ADVANCED"], var.task_governance_metric_level)
    error_message = "Task governance metric level must be one of: DISABLED, ADVANCED."
  }
}

variable "scaling_metric_level" {
  description = "Level of scaling metrics"
  type        = string
  default     = "DISABLED"
  validation {
    condition     = contains(["DISABLED", "ADVANCED"], var.scaling_metric_level)
    error_message = "Scaling metric level must be one of: DISABLED, ADVANCED."
  }
}

variable "cluster_metric_level" {
  description = "Level of cluster metrics"
  type        = string
  default     = "BASIC"
  validation {
    condition     = contains(["BASIC", "ADVANCED"], var.cluster_metric_level)
    error_message = "Cluster metric level must be one of: BASIC, ADVANCED."
  }
}

variable "node_metric_level" {
  description = "Level of node metrics"
  type        = string
  default     = "BASIC"
  validation {
    condition     = contains(["BASIC", "ADVANCED"], var.node_metric_level)
    error_message = "Node metric level must be one of: BASIC, ADVANCED."
  }
}

variable "network_metric_level" {
  description = "Level of network metrics"
  type        = string
  default     = "DISABLED"
  validation {
    condition     = contains(["DISABLED", "ADVANCED"], var.network_metric_level)
    error_message = "Network metric level must be one of: DISABLED, ADVANCED."
  }
}

variable "accelerated_compute_metric_level" {
  description = "Level of accelerated compute metrics"
  type        = string
  default     = "BASIC"
  validation {
    condition     = contains(["BASIC", "ADVANCED"], var.accelerated_compute_metric_level)
    error_message = "Accelerated compute metric level must be one of: BASIC, ADVANCED."
  }
}

variable "logging_enabled" {
  description = "Enable logging"
  type        = bool
  default     = false
}

# HyperPod Task Governance
variable "create_task_governance_module" {
  description = "Whether to enable Task Governance"
  type        = bool
  default     = false
}

variable "task_governance_compute_quotas" {
  description = "SageMaker HyperPod task governance compute allocations to create or update. Only used when create_task_governance_module is true. The description field is managed by Terraform and defaults to an empty string."
  type = list(object({
    name             = string
    description      = optional(string, "")
    activation_state = optional(string, "Enabled")
    compute_quota_resources = list(object({
      instance_type = string
      count         = optional(number)
      accelerators  = optional(number)
      vcpu          = optional(number)
      memory_in_gib = optional(number)
      accelerator_partition = optional(object({
        type  = string
        count = number
      }))
    }))
    resource_sharing_config = optional(object({
      strategy     = optional(string, "LendAndBorrow")
      borrow_limit = optional(number)
      absolute_borrow_limits = optional(list(object({
        instance_type = string
        count         = optional(number)
        accelerators  = optional(number)
        vcpu          = optional(number)
        memory_in_gib = optional(number)
        accelerator_partition = optional(object({
          type  = string
          count = number
        }))
      })), [])
    }), {})
    preempt_team_tasks = optional(string, "LowerPriority")
    target = object({
      team_name         = string
      fair_share_weight = optional(number, 0)
    })
  }))
  default = []

  validation {
    condition = alltrue([
      for quota in var.task_governance_compute_quotas :
      contains(["Enabled", "Disabled"], quota.activation_state)
    ])
    error_message = "Task governance compute quota activation_state must be Enabled or Disabled."
  }

  validation {
    condition = alltrue([
      for quota in var.task_governance_compute_quotas :
      contains(["Lend", "DontLend", "LendAndBorrow"], quota.resource_sharing_config.strategy)
    ])
    error_message = "Task governance compute quota resource_sharing_config.strategy must be Lend, DontLend, or LendAndBorrow."
  }

  validation {
    condition = alltrue([
      for quota in var.task_governance_compute_quotas :
      quota.resource_sharing_config.borrow_limit == null || (quota.resource_sharing_config.borrow_limit >= 1 && quota.resource_sharing_config.borrow_limit <= 500)
    ])
    error_message = "Task governance compute quota resource_sharing_config.borrow_limit must be between 1 and 500 when set."
  }

  validation {
    condition = alltrue([
      for quota in var.task_governance_compute_quotas :
      contains(["Never", "LowerPriority"], quota.preempt_team_tasks)
    ])
    error_message = "Task governance compute quota preempt_team_tasks must be Never or LowerPriority."
  }

  validation {
    condition = alltrue([
      for quota in var.task_governance_compute_quotas :
      quota.target.fair_share_weight >= 0 && quota.target.fair_share_weight <= 100
    ])
    error_message = "Task governance compute quota target.fair_share_weight must be between 0 and 100."
  }

  validation {
    condition = alltrue([
      for quota in var.task_governance_compute_quotas :
      trimspace(quota.name) != "" && trimspace(quota.target.team_name) != ""
    ])
    error_message = "Task governance compute quota name and target.team_name cannot be empty."
  }

  validation {
    condition = alltrue(flatten([
      for quota in var.task_governance_compute_quotas : [
        for resource in concat(quota.compute_quota_resources, quota.resource_sharing_config.absolute_borrow_limits) :
        trimspace(resource.instance_type) != "" &&
        (resource.count == null || resource.count > 0) &&
        (resource.accelerators == null || resource.accelerators > 0) &&
        (resource.vcpu == null || resource.vcpu > 0) &&
        (resource.memory_in_gib == null || resource.memory_in_gib > 0) &&
        (
          resource.accelerator_partition == null ||
          (
            trimspace(resource.accelerator_partition.type) != "" &&
            resource.accelerator_partition.count > 0
          )
        )
      ]
    ]))
    error_message = "Task governance compute quota resource values must be non-empty and positive when set."
  }

  validation {
    condition = alltrue(flatten([
      for quota in var.task_governance_compute_quotas : [
        for resource in quota.compute_quota_resources :
        resource.count != null || resource.accelerators != null || resource.vcpu != null || resource.memory_in_gib != null || resource.accelerator_partition != null
      ]
    ]))
    error_message = "Each task governance compute quota resource must set at least one of count, accelerators, vcpu, memory_in_gib, or accelerator_partition."
  }
}

# HyperPod Training Operator
variable "create_hyperpod_training_operator_module" {
  description = "Whether to enable HyperPod Training Operator"
  type        = bool
  default     = false
}

# HyperPod Inference Operator
variable "create_hyperpod_inference_operator_module" {
  description = "Whether to create HyperPod Inference Operator module"
  type        = bool
  default     = false
}

# Cert Manager (bundled with HyperPod cluster module and required for HPTO and HPIO) 
# If setting create_hyperpod_training_operator_module = true 
# or create_hyperpod_inference_operator_module = true 
# only set enable_cert_manager = false if cert manager was previously installed
variable "enable_cert_manager" {
  description = "Install cert-manager EKS addon"
  type        = bool
  default     = true
}

# S3 CSI Driver (bundled with and required for for HPIO module)
# If setting create_hyperpod_inference_operator_module = true 
# only set enable_s3_csi_driver = false if S3 CSI driver was previously installed
variable "enable_s3_csi_driver" {
  description = "Install S3 Mountpoint CSI driver EKS addon"
  type        = bool
  default     = true
}

# ALB Controller (bundled with and required for for HPIO module)
# If setting create_hyperpod_inference_operator_module = true 
# only set enable_alb_controller = false if ALB Controller was previously installed
variable "enable_alb_controller" {
  description = "Install the ALB Conroller (bundled with HPIO EKS addon)"
  type        = bool
  default     = true
}

# KEDA (bundled with and required for for HPIO module)
# If setting create_hyperpod_inference_operator_module = true 
# only set enable_keda = false if KEDA was previously installed
variable "enable_keda" {
  description = "Install KEDA (bundled with HPIO EKS addon)"
  type        = bool
  default     = true
}

# Metric Server (bundled with but optional for HPIO module)
variable "enable_metrics_server" {
  description = "Install metrics-server EKS addon"
  type        = bool
  default     = true
}

# GuardDuty VPC endpoint cleanup
variable "enable_guardduty_cleanup" {
  description = "Enable automatic cleanup of GuardDuty VPC endpoints during destroy"
  type        = bool
  default     = false
}

# ==========================================
# Cilium CNI Configuration
# ==========================================

variable "enable_cilium" {
  description = "Enable Cilium CNI. When true and creating a new EKS cluster, deploys Cilium and conditionally skips the VPC CNI addon based on cilium_mode."
  type        = bool
  default     = false
}

variable "cilium_mode" {
  description = "Cilium operating mode: overlay (VXLAN tunnel), chaining (policy-only on top of VPC CNI), or custom (user provides all Helm values via cilium_helm_values)."
  type        = string
  default     = "overlay"
  validation {
    condition     = contains(["overlay", "chaining", "custom"], var.cilium_mode)
    error_message = "cilium_mode must be one of: overlay, chaining, custom."
  }
}

variable "cilium_version" {
  description = "Cilium Helm chart version to deploy."
  type        = string
  default     = "1.19.4"
}

variable "cilium_helm_values" {
  description = "Custom Helm values merged on top of mode-specific defaults. In custom mode, this IS the entire Helm config (no base defaults applied). For overlay/eni/chaining modes, these values override the base defaults."
  type        = any
  default     = {}
}
