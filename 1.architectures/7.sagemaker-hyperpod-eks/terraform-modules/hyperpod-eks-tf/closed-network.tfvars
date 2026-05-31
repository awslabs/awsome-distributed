# =============================================================================
# HyperPod EKS Deployment - Create New Closed Network VPC
# =============================================================================
# This configuration creates a brand new closed network environment from scratch
# No internet gateway, NAT gateway, or public subnets
# =============================================================================

resource_name_prefix = "sagemaker-hyperpod-closed"
aws_region           = "us-west-2"

# =============================================================================
# Create New VPC in Closed Network Mode
# =============================================================================
create_vpc_module    = true
closed_network       = true # CRITICAL: No IGW, NAT, or public subnets
vpc_cidr             = "10.192.0.0/16"
public_subnet_1_cidr = "10.192.10.0/24" # Not created in closed network mode
public_subnet_2_cidr = "10.192.11.0/24" # Not created in closed network mode
existing_vpc_id      = ""

# =============================================================================
# Create New HyperPod Private Subnets (Multi-AZ)
# =============================================================================
create_private_subnet_module = true
private_subnet_cidrs         = ["10.1.0.0/16", "10.2.0.0/16", "10.3.0.0/16", "10.4.0.0/16"]
existing_nat_gateway_id      = ""
existing_private_subnet_ids  = []

# =============================================================================
# Create New Security Group
# =============================================================================
create_security_group_module     = true
existing_security_group_id       = ""
create_vpc_endpoint_ingress_rule = true # Adds HTTPS from VPC CIDR for VPC endpoints

# =============================================================================
# Create New EKS Cluster
# =============================================================================
create_eks_module         = true
kubernetes_version        = "1.33"
eks_cluster_name          = "sagemaker-hyperpod-closed-cluster"
existing_eks_cluster_name = ""

# Create new EKS control plane subnets
create_eks_subnets        = true
eks_private_subnet_1_cidr = "10.192.7.0/28"
eks_private_subnet_2_cidr = "10.192.8.0/28"
existing_eks_subnet_ids   = []

# EKS API Endpoint Access (CRITICAL for closed networks)
eks_endpoint_private_access = true # Required for nodes in private subnets to join cluster
eks_endpoint_public_access  = true # Set to false after initial deployment for full isolation

# =============================================================================
# S3 Bucket
# =============================================================================
create_s3_bucket_module = true
existing_s3_bucket_name = ""

# =============================================================================
# VPC Endpoints - Create All for Closed Network
# =============================================================================
create_vpc_endpoints_module      = true
existing_private_route_table_ids = []

# Enable all VPC endpoints for closed network
create_s3_endpoint          = true # S3 gateway endpoint
create_ec2_endpoint         = true # CRITICAL - AWS CNI plugin needs this
create_ecr_api_endpoint     = true # ECR authentication
create_ecr_dkr_endpoint     = true # Pulling container images
create_sts_endpoint         = true # IAM role assumption (IRSA)
create_logs_endpoint        = true # CloudWatch Logs
create_monitoring_endpoint  = true # CloudWatch metrics
create_ssm_endpoint         = true # Systems Manager
create_ssmmessages_endpoint = true # Session Manager
create_ec2messages_endpoint = true # SSM Agent communication
create_eks_auth_endpoint    = true # CRITICAL - EKS Pod Identity authentication

# =============================================================================
# Lifecycle Script
# =============================================================================
create_lifecycle_script_module = true

# =============================================================================
# SageMaker IAM Role
# =============================================================================
create_sagemaker_iam_role_module = true
existing_sagemaker_iam_role_name = ""

# =============================================================================
# Helm Chart with Private ECR Images
# =============================================================================
create_helm_chart_module = true
helm_repo_path           = "helm_chart/HyperPodHelmChart"
helm_repo_revision       = "a0e0b9907b1b0af1fe675f7aceb8b645d6f1ae70" # Updated with ECR images for 011528295005
namespace                = "kube-system"
helm_release_name        = "hyperpod-dependencies"

# Helm chart features
enable_gpu_operator                 = false
enable_mlflow                       = false
enable_kubeflow_training_operators  = true
enable_cluster_role_and_bindings    = false
enable_namespaced_role_and_bindings = false
enable_team_role_and_bindings       = false
enable_nvidia_device_plugin         = true
enable_neuron_device_plugin         = true
enable_mpi_operator                 = true
enable_deep_health_check            = true
enable_job_auto_restart             = true
enable_hyperpod_patching            = true

# =============================================================================
# HyperPod Cluster Configuration
# =============================================================================
create_hyperpod_module       = true
hyperpod_cluster_name        = "ml-cluster-closed"
auto_node_recovery           = true
continuous_provisioning_mode = true
karpenter_autoscaling        = true

# Single m5.12xlarge instance for testing
instance_groups = [
  {
    name                      = "closed-worker-group"
    instance_type             = "ml.m5.12xlarge"
    instance_count            = 1
    availability_zone_id      = "usw2-az1" # us-west-2a
    ebs_volume_size_in_gb     = 100
    threads_per_core          = 2
    enable_stress_check       = false
    enable_connectivity_check = false
    lifecycle_script          = "on_create.sh"
  }
]

# =============================================================================
# Optional Features 
# =============================================================================
create_fsx_module                         = true
create_task_governance_module             = false
create_hyperpod_training_operator_module  = false
create_hyperpod_inference_operator_module = false
create_observability_module               = true
