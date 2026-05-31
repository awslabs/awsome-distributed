variable "resource_name_prefix" {
  description = "Prefix to be used for all resources created by this module"
  type        = string
}

variable "vpc_id" {
  description = "The ID of the VPC"
  type        = string
}

variable "create_new_sg" {
  description = "Whether to create a new security group"
  type        = bool
  default     = true
}

variable "existing_security_group_id" {
  description = "The ID of an existing security group"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Additional tags for all resources"
  type        = map(string)
  default     = {}
}

variable "existing_eks_cluster_name" {
  description = "Name of existing EKS cluster to attach the security group to"
  type        = string
  default     = ""
}

variable "create_vpc_endpoint_ingress_rule" {
  description = "Whether to create HTTPS ingress rule from VPC CIDR for VPC endpoints"
  type        = bool
  default     = true
}

variable "enable_vxlan_rule" {
  description = "Add UDP 8472 intra-SG rules for Cilium VXLAN overlay mode."
  type        = bool
  default     = false
}
