data "aws_region" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# Conditionally create new subnets or use existing ones
locals {
  eks_subnet_ids = var.create_eks_subnets ? aws_subnet.private[*].id : var.existing_eks_subnet_ids
}

resource "aws_subnet" "private" {
  count             = var.create_eks_subnets ? length(var.private_subnet_cidrs) : 0
  vpc_id            = var.vpc_id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name                                            = "${var.resource_name_prefix}-private-subnet-${count.index + 1}"
    "kubernetes.io/role/internal-elb"               = "1"
    "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
  }
}

resource "aws_route_table" "eks_private" {
  count  = var.create_eks_subnets ? length(var.private_subnet_cidrs) : 0
  vpc_id = var.vpc_id

  tags = {
    Name = "${var.resource_name_prefix}-EKS-Private-RT-${count.index + 1}"
  }
}

resource "aws_route_table_association" "private" {
  count          = var.create_eks_subnets ? length(aws_subnet.private) : 0
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.eks_private[count.index].id
}

resource "aws_iam_role" "eks_cluster_role" {
  name = "${var.resource_name_prefix}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_cloudwatch_log_group" "eks_cluster" {
  name              = "/aws/eks/${var.eks_cluster_name}/cluster"
  retention_in_days = 7
}

resource "aws_eks_cluster" "cluster" {
  name     = var.eks_cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.eks_cluster_role.arn

  vpc_config {
    subnet_ids              = local.eks_subnet_ids
    security_group_ids      = [var.security_group_id]
    endpoint_private_access = var.endpoint_private_access
    endpoint_public_access  = var.endpoint_public_access
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  enabled_cluster_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler"
  ]

  depends_on = [
    aws_cloudwatch_log_group.eks_cluster,
    aws_iam_role_policy_attachment.eks_cluster_policy
  ]
}

# These EKS addons can become active before nodes are available  
resource "aws_eks_addon" "vpc_cni" {
  count                       = var.skip_vpc_cni ? 0 : 1
  cluster_name                = aws_eks_cluster.cluster.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.cluster.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "pod_identity" {
  cluster_name                = aws_eks_cluster.cluster.name
  addon_name                  = "eks-pod-identity-agent"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

# This EKS addons will remain degraded until nodes are available
# Add CoreDNS using AWS CLI so that Terraform doesn't wait for it to be active
resource "null_resource" "coredns_addon" {
  provisioner "local-exec" {
    command = "aws eks create-addon --region ${data.aws_region.current.region} --cluster-name ${aws_eks_cluster.cluster.name} --addon-name coredns"
  }

  depends_on = [aws_eks_cluster.cluster]
}