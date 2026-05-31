variable "resource_name_prefix" {
  description = "Prefix to be used for all resources created by this module"
  type        = string
}

variable "s3_bucket_name" {
  description = "The name of the S3 bucket used to store the cluster lifecycle scripts"
  type        = string
}

variable "tags" {
  description = "Additional tags for all resources"
  type        = map(string)
  default     = {}
}

variable "rig_input_s3_bucket" {
  description = "The name of the RIG input S3 bucket"
  type        = string
}

variable "rig_output_s3_bucket" {
  description = "The name of the RIG output S3 bucket"
  type        = string
}


variable "rig_mode" {
  description = "Whether restricted instance groups are configured"
  type        = bool
}

variable "gated_access" {
  description = "Whether to include gated access permissions"
  type        = bool
}

variable "eks_cluster_arn" {
  description = "The ARN of the EKS cluster"
  type        = string
}

variable "vpc_id" {
  description = "The ID of the VPC used"
  type        = string
}

variable "security_group_id" {
  description = "The ID of the security group used"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs"
  type        = list(string)
}

variable "rig_rft_lambda_access" {
  description = "Whether to include Lambda access permissions for RFT"
  type        = bool
}

variable "rig_rft_sqs_access" {
  description = "Whether to include SQS access permissions for RFT"
  type        = bool
}

variable "karpenter_autoscaling" {
  description = "Whether to enable Karpenter autoscaling"
  type        = bool
}