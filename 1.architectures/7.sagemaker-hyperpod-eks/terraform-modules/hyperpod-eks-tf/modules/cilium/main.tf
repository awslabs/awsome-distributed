locals {
  overlay_values = {
    routingMode    = "tunnel"
    tunnelProtocol = "vxlan"
    ipam = {
      mode = "cluster-pool"
    }
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
    chaining = local.chaining_values
    custom   = {}
  }

  # Merge: user values override base values. In custom mode, base is empty.
  effective_values = merge(local.base_values[var.cilium_mode], var.cilium_helm_values)
}

resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = var.cilium_version
  namespace  = "kube-system"

  values = [yamlencode(local.effective_values)]

  # Do not wait for DaemonSet readiness — Cilium pods can only schedule
  # once HyperPod nodes join the cluster, which happens after this module.
  wait          = false
  wait_for_jobs = false
  timeout       = 600
}
