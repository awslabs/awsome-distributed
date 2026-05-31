variable "resource_name_prefix" {
  description = "Prefix to be used for all resources created by this module"
  type        = string
  default     = "sagemaker-hyperpod-eks"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "vpc_id" {
  description = "The ID of the VPC where endpoints will be created"
  type        = string
}

variable "security_group_id" {
  description = "The security group ID for the VPC endpoints"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for VPC endpoints"
  type        = list(string)
}

variable "eks_cluster_name" {
  description = "The name of the EKS cluster"
  type        = string
}

variable "eks_cluster_arn" {
  description = "The ARN of the EKS cluster"
  type        = string
}

# AMP variables
variable "create_prometheus_workspace" {
  description = "Specify whether to create a new Amazon Managed Service for Prometheus (AMP) workspace"
  type        = bool
  default     = true
}

variable "prometheus_workspace_id" {
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

variable "grafana_workspace_id" {
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
}

variable "task_governance_metric_level" {
  description = "Level of task governance metrics"
  type        = string
  default     = "DISABLED"
}

variable "scaling_metric_level" {
  description = "Level of scaling metrics"
  type        = string
  default     = "DISABLED"
}

variable "cluster_metric_level" {
  description = "Level of cluster metrics"
  type        = string
  default     = "BASIC"
}

variable "node_metric_level" {
  description = "Level of node metrics"
  type        = string
  default     = "BASIC"
}

variable "network_metric_level" {
  description = "Level of network metrics"
  type        = string
  default     = "DISABLED"
}

variable "accelerated_compute_metric_level" {
  description = "Level of accelerated compute metrics"
  type        = string
  default     = "BASIC"
}

variable "logging_enabled" {
  description = "Enable logging"
  type        = bool
  default     = false
}

