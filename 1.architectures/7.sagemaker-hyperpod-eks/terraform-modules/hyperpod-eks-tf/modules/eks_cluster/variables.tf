variable "resource_name_prefix" {
  description = "Prefix to be used for all resources created by this module"
  type        = string
  default     = "sagemaker-hyperpod-eks"
}

variable "eks_cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "vpc_id" {
  description = "The ID of the VPC"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.31"
}

variable "security_group_id" {
  description = "ID of the security group for the EKS cluster"
  type        = string
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (only used if create_eks_subnets is true)"
  type        = list(string)
  default     = []
}

variable "nat_gateway_id" {
  description = "ID of the NAT gateway for the EKS cluster (only used if create_eks_subnets is true)"
  type        = string
  default     = ""
}

variable "create_eks_subnets" {
  description = "Whether to create new subnets for EKS or use existing ones"
  type        = bool
  default     = true
}

variable "existing_eks_subnet_ids" {
  description = "List of existing subnet IDs to use for EKS (only used if create_eks_subnets is false)"
  type        = list(string)
  default     = []
}

variable "endpoint_private_access" {
  description = "Enable private API server endpoint (required for closed networks)"
  type        = bool
  default     = true
}

variable "endpoint_public_access" {
  description = "Enable public API server endpoint (should be false for closed networks)"
  type        = bool
  default     = true
}

variable "skip_vpc_cni" {
  description = "Skip deploying the VPC CNI EKS addon (used when Cilium replaces VPC CNI)."
  type        = bool
  default     = false
}
