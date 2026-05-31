data "aws_region" "current" {}

# Gateway Endpoint - S3
resource "aws_vpc_endpoint" "s3" {
  count = var.create_s3_endpoint ? 1 : 0

  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  route_table_ids   = var.private_route_table_ids
  vpc_endpoint_type = "Gateway"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = "*"
        Action    = "*"
        Resource  = "*"
      }
    ]
  })
  tags = {
    Name = "${var.resource_name_prefix}-s3-vpc-endpoint"
  }
}

# Interface Endpoints - Critical for EKS
resource "aws_vpc_endpoint" "ec2" {
  count = var.create_ec2_endpoint ? 1 : 0

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.ec2"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [var.security_group_id]
  private_dns_enabled = true

  tags = {
    Name        = "${var.resource_name_prefix}-ec2-vpc-endpoint"
    Description = "CRITICAL for AWS CNI plugin"
  }
}

resource "aws_vpc_endpoint" "ecr_api" {
  count = var.create_ecr_api_endpoint ? 1 : 0

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [var.security_group_id]
  private_dns_enabled = true

  tags = {
    Name = "${var.resource_name_prefix}-ecr-api-vpc-endpoint"
  }
}

resource "aws_vpc_endpoint" "ecr_dkr" {
  count = var.create_ecr_dkr_endpoint ? 1 : 0

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [var.security_group_id]
  private_dns_enabled = true

  tags = {
    Name = "${var.resource_name_prefix}-ecr-dkr-vpc-endpoint"
  }
}

resource "aws_vpc_endpoint" "sts" {
  count = var.create_sts_endpoint ? 1 : 0

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.sts"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [var.security_group_id]
  private_dns_enabled = true

  tags = {
    Name = "${var.resource_name_prefix}-sts-vpc-endpoint"
  }
}

resource "aws_vpc_endpoint" "logs" {
  count = var.create_logs_endpoint ? 1 : 0

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [var.security_group_id]
  private_dns_enabled = true

  tags = {
    Name = "${var.resource_name_prefix}-logs-vpc-endpoint"
  }
}

resource "aws_vpc_endpoint" "monitoring" {
  count = var.create_monitoring_endpoint ? 1 : 0

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.monitoring"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [var.security_group_id]
  private_dns_enabled = true

  tags = {
    Name = "${var.resource_name_prefix}-monitoring-vpc-endpoint"
  }
}

# SSM Endpoints - For Systems Manager access
resource "aws_vpc_endpoint" "ssm" {
  count = var.create_ssm_endpoint ? 1 : 0

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [var.security_group_id]
  private_dns_enabled = true

  tags = {
    Name = "${var.resource_name_prefix}-ssm-vpc-endpoint"
  }
}

resource "aws_vpc_endpoint" "ssmmessages" {
  count = var.create_ssmmessages_endpoint ? 1 : 0

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [var.security_group_id]
  private_dns_enabled = true

  tags = {
    Name = "${var.resource_name_prefix}-ssmmessages-vpc-endpoint"
  }
}

resource "aws_vpc_endpoint" "ec2messages" {
  count = var.create_ec2messages_endpoint ? 1 : 0

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [var.security_group_id]
  private_dns_enabled = true

  tags = {
    Name = "${var.resource_name_prefix}-ec2messages-vpc-endpoint"
  }
}

# EKS Auth Endpoint - Required for EKS Pod Identity
resource "aws_vpc_endpoint" "eks_auth" {
  count = var.create_eks_auth_endpoint ? 1 : 0

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.eks-auth"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [var.security_group_id]
  private_dns_enabled = true

  tags = {
    Name        = "${var.resource_name_prefix}-eks-auth-vpc-endpoint"
    Description = "CRITICAL for EKS Pod Identity authentication"
  }
}

# RIG Mode Endpoints (conditional)
resource "aws_vpc_endpoint" "lambda" {
  count = var.rig_mode && var.rig_rft_lambda_access ? 1 : 0

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.lambda"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [var.security_group_id]
  private_dns_enabled = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = "*"
        Action    = "*"
        Resource  = "*"
      }
    ]
  })
  tags = {
    Name = "${var.resource_name_prefix}-lambda-vpc-endpoint"
  }
}

resource "aws_vpc_endpoint" "sqs" {
  count = var.rig_mode && var.rig_rft_sqs_access ? 1 : 0

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.sqs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [var.security_group_id]
  private_dns_enabled = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = "*"
        Action    = "*"
        Resource  = "*"
      }
    ]
  })
  tags = {
    Name = "${var.resource_name_prefix}-sqs-vpc-endpoint"
  }
}