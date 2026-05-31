variable "eks_cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "cilium_mode" {
  description = "Cilium operating mode: overlay, chaining, or custom."
  type        = string
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
  description = "Custom Helm values merged on top of mode-specific defaults. In custom mode, this IS the entire config."
  type        = any
  default     = {}
}
