data "aws_region" "current" {}

data "aws_eks_cluster" "existing_eks_cluster" {
  count = var.create_eks_module ? 0 : 1
  name  = var.existing_eks_cluster_name
}

data "aws_s3_bucket" "existing_s3_bucket" {
  count  = var.create_s3_bucket_module ? 0 : (var.existing_s3_bucket_name != "" ? 1 : 0)
  bucket = var.existing_s3_bucket_name
}

# Get subnet info when using existing subnets
data "aws_subnet" "existing_private_subnets" {
  count = var.create_private_subnet_module ? 0 : length(var.existing_private_subnet_ids)
  id    = var.existing_private_subnet_ids[count.index]
}

locals {
  # Generate az_to_subnet_map for existing subnets
  az_to_subnet_map = var.create_private_subnet_module ? module.private_subnet[0].az_to_subnet_map : zipmap(data.aws_subnet.existing_private_subnets[*].availability_zone_id, data.aws_subnet.existing_private_subnets[*].id)

  # AMP allowed regions for observability
  amp_allowed_regions = [
    "us-east-1", "us-east-2", "us-west-2", "us-west-1",
    "ap-south-1", "ap-northeast-1", "ap-southeast-1", "ap-southeast-2", "ap-southeast-3", "ap-southeast-4",
    "eu-central-1", "eu-west-1", "eu-west-2", "eu-north-1", "eu-south-2",
    "sa-east-1"
  ]
  is_amp_allowed = contains(local.amp_allowed_regions, var.aws_region)

  vpc_id                   = var.create_vpc_module ? module.vpc[0].vpc_id : var.existing_vpc_id
  private_subnet_ids       = var.create_private_subnet_module ? module.private_subnet[0].private_subnet_ids : var.existing_private_subnet_ids
  security_group_id        = var.create_security_group_module ? module.security_group[0].security_group_id : var.existing_security_group_id
  eks_cluster_name         = var.create_eks_module ? module.eks_cluster[0].eks_cluster_name : var.existing_eks_cluster_name
  eks_cluster_arn          = var.create_eks_module ? module.eks_cluster[0].eks_cluster_arn : data.aws_eks_cluster.existing_eks_cluster[0].arn
  sagemaker_iam_role_name  = var.create_sagemaker_iam_role_module ? module.sagemaker_iam_role[0].sagemaker_iam_role_name : var.existing_sagemaker_iam_role_name
  create_hyperpod_module   = var.create_hyperpod_module && !(var.create_eks_module && !var.create_helm_chart_module)
  karpenter_role_arn       = var.create_sagemaker_iam_role_module && length(module.sagemaker_iam_role[0].karpenter_role_arn) > 0 ? module.sagemaker_iam_role[0].karpenter_role_arn[0] : null
  nat_gateway_id           = var.create_vpc_module ? module.vpc[0].nat_gateway_1_id : var.existing_nat_gateway_id
  private_route_table_ids  = var.create_private_subnet_module ? module.private_subnet[0].private_route_table_ids : var.existing_private_route_table_ids
  eks_private_subnet_cidrs = [var.eks_private_subnet_1_cidr, var.eks_private_subnet_2_cidr]
  enable_guardduty_cleanup = var.enable_guardduty_cleanup && (var.create_vpc_module || var.create_private_subnet_module || var.create_eks_module)

  # Cilium CNI
  skip_vpc_cni  = var.enable_cilium && var.cilium_mode != "chaining"
  create_cilium = var.enable_cilium && var.create_eks_module

  # Features that require waiting for nodes
  features_requiring_nodes = [
    var.create_hyperpod_training_operator_module,
    var.create_hyperpod_inference_operator_module,
    var.create_observability_module,
    var.create_task_governance_module,
    var.create_fsx_module
  ]

  # Disabled feature set for RIGs
  rig_mode                                  = length(var.restricted_instance_groups) > 0
  instance_groups                           = !local.rig_mode ? var.instance_groups : []
  create_s3_bucket_module                   = !local.rig_mode && var.create_s3_bucket_module
  s3_bucket_name                            = !local.rig_mode ? (var.create_s3_bucket_module ? module.s3_bucket[0].s3_bucket_name : var.existing_s3_bucket_name) : null
  create_lifecycle_script_module            = !local.rig_mode && var.create_lifecycle_script_module
  enable_cert_manager                       = !local.rig_mode && var.enable_cert_manager && (var.create_hyperpod_training_operator_module || var.create_hyperpod_inference_operator_module)
  wait_for_nodes                            = !local.rig_mode && anytrue(local.features_requiring_nodes)
  create_fsx_module                         = !local.rig_mode ? var.create_fsx_module : false
  create_task_governance_module             = !local.rig_mode && var.create_task_governance_module
  create_hyperpod_training_operator_module  = !local.rig_mode && var.create_hyperpod_training_operator_module
  create_observability_module               = !local.rig_mode && var.create_observability_module
  create_hyperpod_inference_operator_module = !local.rig_mode && var.create_hyperpod_inference_operator_module
}

module "vpc" {
  count  = var.create_vpc_module ? 1 : 0
  source = "./modules/vpc"

  resource_name_prefix = var.resource_name_prefix
  vpc_cidr             = var.vpc_cidr
  public_subnet_1_cidr = var.public_subnet_1_cidr
  public_subnet_2_cidr = var.public_subnet_2_cidr
  closed_network       = var.closed_network
}

module "private_subnet" {
  count  = var.create_private_subnet_module ? 1 : 0
  source = "./modules/private_subnet"

  resource_name_prefix = var.resource_name_prefix
  vpc_id               = local.vpc_id
  private_subnet_cidrs = var.private_subnet_cidrs
  nat_gateway_id       = local.nat_gateway_id
  closed_network       = var.closed_network
}

module "security_group" {
  count  = var.create_security_group_module ? 1 : 0
  source = "./modules/security_group"

  resource_name_prefix             = var.resource_name_prefix
  vpc_id                           = local.vpc_id
  create_new_sg                    = var.create_eks_module
  existing_security_group_id       = var.existing_security_group_id
  create_vpc_endpoint_ingress_rule = var.create_vpc_endpoint_ingress_rule
  enable_vxlan_rule                = var.enable_cilium && var.cilium_mode == "overlay"
}

module "eks_cluster" {
  count  = var.create_eks_module ? 1 : 0
  source = "./modules/eks_cluster"

  resource_name_prefix    = var.resource_name_prefix
  vpc_id                  = local.vpc_id
  eks_cluster_name        = var.eks_cluster_name
  kubernetes_version      = var.kubernetes_version
  security_group_id       = local.security_group_id
  create_eks_subnets      = var.create_eks_subnets
  existing_eks_subnet_ids = var.existing_eks_subnet_ids
  private_subnet_cidrs    = local.eks_private_subnet_cidrs
  nat_gateway_id          = local.nat_gateway_id
  endpoint_private_access = var.eks_endpoint_private_access
  endpoint_public_access  = var.eks_endpoint_public_access
  skip_vpc_cni            = local.skip_vpc_cni
}

module "cilium" {
  count  = local.create_cilium ? 1 : 0
  source = "./modules/cilium"

  eks_cluster_name   = module.eks_cluster[0].eks_cluster_name
  cilium_mode        = var.cilium_mode
  cilium_version     = var.cilium_version
  cilium_helm_values = var.cilium_helm_values

  depends_on = [module.eks_cluster]
}

module "s3_bucket" {
  count  = local.create_s3_bucket_module ? 1 : 0
  source = "./modules/s3_bucket"

  resource_name_prefix = var.resource_name_prefix
}

module "vpc_endpoints" {
  count  = var.create_vpc_endpoints_module ? 1 : 0
  source = "./modules/vpc_endpoints"

  resource_name_prefix    = var.resource_name_prefix
  vpc_id                  = local.vpc_id
  private_route_table_ids = local.private_route_table_ids
  private_subnet_ids      = local.private_subnet_ids
  security_group_id       = local.security_group_id
  rig_mode                = local.rig_mode
  rig_rft_lambda_access   = var.rig_rft_lambda_access
  rig_rft_sqs_access      = var.rig_rft_sqs_access

  # Closed Network - VPC Endpoint Configuration
  create_s3_endpoint          = var.create_s3_endpoint
  create_ec2_endpoint         = var.create_ec2_endpoint
  create_ecr_api_endpoint     = var.create_ecr_api_endpoint
  create_ecr_dkr_endpoint     = var.create_ecr_dkr_endpoint
  create_sts_endpoint         = var.create_sts_endpoint
  create_logs_endpoint        = var.create_logs_endpoint
  create_monitoring_endpoint  = var.create_monitoring_endpoint
  create_ssm_endpoint         = var.create_ssm_endpoint
  create_ssmmessages_endpoint = var.create_ssmmessages_endpoint
  create_ec2messages_endpoint = var.create_ec2messages_endpoint
  create_eks_auth_endpoint    = var.create_eks_auth_endpoint

  depends_on = [
    module.private_subnet,
    module.security_group
  ]
}

module "lifecycle_script" {
  count  = local.create_lifecycle_script_module ? 1 : 0
  source = "./modules/lifecycle_script"

  resource_name_prefix = var.resource_name_prefix
  s3_bucket_name       = local.s3_bucket_name
}

module "sagemaker_iam_role" {
  count  = var.create_sagemaker_iam_role_module ? 1 : 0
  source = "./modules/sagemaker_iam_role"

  resource_name_prefix  = var.resource_name_prefix
  s3_bucket_name        = local.s3_bucket_name
  rig_input_s3_bucket   = var.rig_input_s3_bucket
  rig_output_s3_bucket  = var.rig_output_s3_bucket
  eks_cluster_arn       = local.eks_cluster_arn
  security_group_id     = local.security_group_id
  private_subnet_ids    = local.private_subnet_ids
  vpc_id                = local.vpc_id
  rig_mode              = local.rig_mode
  gated_access          = var.gated_access
  rig_rft_lambda_access = var.rig_rft_lambda_access
  rig_rft_sqs_access    = var.rig_rft_sqs_access
  karpenter_autoscaling = var.karpenter_autoscaling
}

module "helm_chart" {
  count  = var.create_helm_chart_module ? 1 : 0
  source = "./modules/helm_chart"

  resource_name_prefix                = var.resource_name_prefix
  helm_repo_path                      = var.helm_repo_path
  helm_release_name                   = var.helm_release_name
  helm_repo_revision                  = var.helm_repo_revision
  helm_repo_revision_rig              = var.helm_repo_revision_rig
  namespace                           = var.namespace
  eks_cluster_name                    = local.eks_cluster_name
  enable_gpu_operator                 = var.enable_gpu_operator
  enable_mlflow                       = var.enable_mlflow
  enable_kubeflow_training_operators  = var.enable_kubeflow_training_operators
  enable_cluster_role_and_bindings    = var.enable_cluster_role_and_bindings
  enable_namespaced_role_and_bindings = var.enable_namespaced_role_and_bindings
  enable_team_role_and_bindings       = var.enable_team_role_and_bindings
  enable_nvidia_device_plugin         = var.enable_nvidia_device_plugin
  enable_neuron_device_plugin         = var.enable_neuron_device_plugin
  enable_mpi_operator                 = var.enable_mpi_operator
  enable_deep_health_check            = var.enable_deep_health_check
  enable_job_auto_restart             = var.enable_job_auto_restart
  enable_hyperpod_patching            = var.enable_hyperpod_patching
  rig_script_path                     = var.rig_script_path
  rig_mode                            = local.rig_mode

  depends_on = [module.eks_cluster, module.cilium]
}

module "hyperpod_cluster" {
  count  = local.create_hyperpod_module ? 1 : 0
  source = "./modules/hyperpod_cluster"

  resource_name_prefix         = var.resource_name_prefix
  hyperpod_cluster_name        = var.hyperpod_cluster_name
  auto_node_recovery           = var.auto_node_recovery
  instance_groups              = local.instance_groups
  restricted_instance_groups   = var.restricted_instance_groups
  private_subnet_ids           = local.private_subnet_ids
  az_to_subnet_map             = local.az_to_subnet_map
  security_group_id            = local.security_group_id
  eks_cluster_name             = local.eks_cluster_name
  eks_cluster_arn              = local.eks_cluster_arn
  s3_bucket_name               = local.s3_bucket_name
  sagemaker_iam_role_name      = local.sagemaker_iam_role_name
  rig_mode                     = local.rig_mode
  karpenter_autoscaling        = var.karpenter_autoscaling
  continuous_provisioning_mode = var.continuous_provisioning_mode
  karpenter_role_arn           = local.karpenter_role_arn
  wait_for_nodes               = local.wait_for_nodes
  enable_cert_manager          = local.enable_cert_manager

  depends_on = [
    module.helm_chart,
    module.eks_cluster,
    module.private_subnet,
    module.security_group,
    module.s3_bucket,
    module.vpc_endpoints,
    module.sagemaker_iam_role
  ]
}

module "task_governance" {
  count  = local.create_task_governance_module ? 1 : 0
  source = "./modules/task_governance"

  aws_region           = var.aws_region
  compute_quotas       = var.task_governance_compute_quotas
  eks_cluster_name     = local.eks_cluster_name
  hyperpod_cluster_arn = length(module.hyperpod_cluster) > 0 ? module.hyperpod_cluster[0].hyperpod_cluster_arn : ""

  depends_on = [module.hyperpod_cluster]
}

module "fsx_lustre" {
  count  = local.create_fsx_module ? 1 : 0
  source = "./modules/fsx_lustre"

  resource_name_prefix       = var.resource_name_prefix
  eks_cluster_name           = local.eks_cluster_name
  subnet_id                  = module.hyperpod_cluster[0].primary_subnet_id
  security_group_id          = local.security_group_id
  create_new_filesystem      = var.create_new_fsx_filesystem
  storage_capacity           = var.fsx_storage_capacity
  throughput                 = var.fsx_throughput
  data_compression_type      = var.fsx_data_compression_type
  file_system_type_version   = var.fsx_file_system_type_version
  inference_operator_enabled = local.create_hyperpod_inference_operator_module
  fsx_pvc_namespace          = var.fsx_pvc_namespace
  create_fsx_pvc_namespace   = var.create_fsx_pvc_namespace

  depends_on = [
    module.hyperpod_cluster,
    module.task_governance
  ]
}

module "hyperpod_training_operator" {
  count  = local.create_hyperpod_training_operator_module ? 1 : 0
  source = "./modules/hyperpod_training_operator"

  resource_name_prefix = var.resource_name_prefix
  eks_cluster_name     = var.eks_cluster_name

  depends_on = [
    module.hyperpod_cluster,
    module.task_governance
  ]
}

module "hyperpod_inference_operator" {
  count  = local.create_hyperpod_inference_operator_module ? 1 : 0
  source = "./modules/hyperpod_inference_operator"

  resource_name_prefix    = var.resource_name_prefix
  eks_cluster_name        = local.eks_cluster_name
  hyperpod_cluster_arn    = module.hyperpod_cluster[0].hyperpod_cluster_arn
  access_logs_bucket_name = module.s3_bucket[0].s3_logs_bucket_name
  enable_s3_csi_driver    = var.enable_s3_csi_driver
  enable_alb_controller   = var.enable_alb_controller
  enable_keda             = var.enable_keda
  enable_metrics_server   = var.enable_metrics_server

  depends_on = [
    module.hyperpod_cluster,
    module.task_governance
  ]
}

module "observability" {
  count  = local.create_observability_module && local.is_amp_allowed ? 1 : 0
  source = "./modules/observability"

  # requires direct reference to region to determine if Grafana is allowed at plan time 
  aws_region                       = var.aws_region
  resource_name_prefix             = var.resource_name_prefix
  vpc_id                           = local.vpc_id
  security_group_id                = local.security_group_id
  private_subnet_ids               = local.private_subnet_ids
  eks_cluster_name                 = local.eks_cluster_name
  eks_cluster_arn                  = local.eks_cluster_arn
  create_grafana_workspace         = var.create_grafana_workspace
  create_prometheus_workspace      = var.create_prometheus_workspace
  prometheus_workspace_id          = var.existing_prometheus_workspace_id
  grafana_workspace_id             = var.existing_grafana_workspace_id
  prometheus_workspace_name        = var.prometheus_workspace_name
  grafana_workspace_name           = var.grafana_workspace_name
  training_metric_level            = var.training_metric_level
  task_governance_metric_level     = var.task_governance_metric_level
  scaling_metric_level             = var.scaling_metric_level
  cluster_metric_level             = var.cluster_metric_level
  node_metric_level                = var.node_metric_level
  network_metric_level             = var.network_metric_level
  accelerated_compute_metric_level = var.accelerated_compute_metric_level
  logging_enabled                  = var.logging_enabled

  depends_on = [
    module.hyperpod_cluster,
    module.task_governance
  ]
}

# GuardDuty VPC endpoint cleanup
resource "null_resource" "guardduty_cleanup" {
  count = local.enable_guardduty_cleanup ? 1 : 0

  # capture values in apply time to use in destroy time
  triggers = {
    vpc_id = local.vpc_id
    region = data.aws_region.current.region
  }

  provisioner "local-exec" {
    when    = destroy
    command = "${path.module}/scripts/guardduty-cleanup.sh ${self.triggers.region} ${self.triggers.vpc_id}"
  }

  depends_on = [
    module.vpc,
    module.private_subnet,
    module.eks_cluster
  ]
}
