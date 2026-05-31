data "aws_region" "current" {}

locals {
  revision            = var.rig_mode ? var.helm_repo_revision_rig : var.helm_repo_revision
  rig_script_dir      = var.rig_mode ? dirname(var.rig_script_path) : ""
  rig_script_filename = var.rig_mode ? basename(var.rig_script_path) : ""
}

resource "null_resource" "git_checkout" {
  provisioner "local-exec" {
    command = <<-EOT
      cd /tmp/helm-repo
      git reset --hard HEAD
      git clean -fd
      git checkout ${local.revision}
    EOT
  }
}

resource "null_resource" "add_helm_repos" {
  provisioner "local-exec" {
    command = <<-EOT
      helm repo add nvidia https://nvidia.github.io/k8s-device-plugin
      helm repo add eks https://aws.github.io/eks-charts/
      helm repo update
    EOT
  }
}

resource "helm_release" "hyperpod" {
  name              = var.helm_release_name
  chart             = "/tmp/helm-repo/${var.helm_repo_path}"
  namespace         = var.namespace
  dependency_update = true
  wait              = false

  values = fileexists("/tmp/helm-repo/${var.helm_repo_path}/regional-values/values-${data.aws_region.current.region}.yaml") ? [
    file("/tmp/helm-repo/${var.helm_repo_path}/regional-values/values-${data.aws_region.current.region}.yaml")
  ] : []

  set = [
    {
      name  = "mlflow.enabled"
      value = var.enable_mlflow
    },
    {
      name  = "trainingOperators.enabled"
      value = var.enable_kubeflow_training_operators
    },
    {
      name  = "cluster-role-and-bindings.enabled"
      value = var.enable_cluster_role_and_bindings
    },
    {
      name  = "namespaced-role-and-bindings.enable"
      value = var.enable_namespaced_role_and_bindings
    },
    {
      name  = "team-role-and-bindings.enabled"
      value = var.enable_team_role_and_bindings
    },
    {
      name  = "gpu-operator.enabled"
      value = var.enable_gpu_operator
    },
    {
      name  = "nvidia-device-plugin.devicePlugin.enabled"
      value = var.enable_gpu_operator ? false : var.enable_nvidia_device_plugin
    },
    {
      name  = "neuron-device-plugin.devicePlugin.enabled"
      value = var.enable_neuron_device_plugin
    },
    {
      name  = "mpi-operator.enabled"
      value = var.enable_mpi_operator
    },
    {
      name  = "health-monitoring-agent.region",
      value = data.aws_region.current.region
    },
    {
      name  = "deep-health-check.enabled"
      value = var.enable_deep_health_check
    },
    {
      name  = "job-auto-restart.enabled"
      value = var.enable_job_auto_restart
    },
    {
      name  = "hyperpod-patching.enabled"
      value = var.enable_hyperpod_patching
    },
    {
      name  = "cert-manager.enabled"
      value = "false"
    }
  ]
  depends_on = [
    null_resource.add_helm_repos,
    null_resource.git_checkout
  ]
}

resource "null_resource" "run_rig_script" {
  count = var.rig_mode ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      aws eks update-kubeconfig --region ${data.aws_region.current.region} --name ${var.eks_cluster_name}
      cd /tmp/helm-repo/${local.rig_script_dir}
      chmod +x ${local.rig_script_filename}
      echo "y" | ./${local.rig_script_filename}
    EOT
  }

  depends_on = [helm_release.hyperpod]
}

resource "null_resource" "git_cleanup" {
  provisioner "local-exec" {
    command = <<-EOT
      cd /tmp/helm-repo
      git reset --hard HEAD
      git clean -fd
      git checkout main
    EOT
  }

  depends_on = [
    helm_release.hyperpod,
    null_resource.run_rig_script
  ]
}
