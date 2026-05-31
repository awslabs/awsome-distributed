output "cilium_release_name" {
  description = "Name of the Cilium Helm release"
  value       = helm_release.cilium.name
}

output "cilium_release_namespace" {
  description = "Namespace of the Cilium Helm release"
  value       = helm_release.cilium.namespace
}

output "cilium_mode" {
  description = "Cilium operating mode that was deployed"
  value       = var.cilium_mode
}
