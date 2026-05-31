data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  arn_slug = "${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}"
  #eks_cluster_arn = "arn:aws:eks:${local.arn_slug}:cluster/${var.eks_cluster_name}"
  ec2_arn_prefix = "arn:aws:ec2:${local.arn_slug}"
}

# IAM Role
resource "aws_iam_role" "sagemaker_execution_role" {
  name = "${var.resource_name_prefix}-SMHP-Exec-Role-${data.aws_region.current.region}"
  path = "/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "sagemaker.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = var.tags
}

# Attach Managed IAM Policy to the IAM Role
resource "aws_iam_role_policy_attachment" "sagemaker_managed_policy_attachment" {
  role       = aws_iam_role.sagemaker_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSageMakerClusterInstanceRolePolicy"
}

# Custom EKS CNI IAM Policy 
resource "aws_iam_policy" "eks_cni_policy" {
  name = "${var.resource_name_prefix}-EKS_CNI_Policy-${data.aws_region.current.region}"
  path = "/"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:AttachNetworkInterface"
        ]
        Resource = [
          "${local.ec2_arn_prefix}:instance/*",
          "${local.ec2_arn_prefix}:network-interface/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeTags",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeSubnets",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateTags"
        ]
        Resource = "arn:aws:ec2:*:*:network-interface/*"
      }
    ]
  })
}

# Attach Custom EKS CNI Policy to the IAM Role
resource "aws_iam_role_policy_attachment" "eks_cni_policy_attachment" {
  role       = aws_iam_role.sagemaker_execution_role.name
  policy_arn = aws_iam_policy.eks_cni_policy.arn
}

# Custom IAM Policy
resource "aws_iam_policy" "sagemaker_execution_policy" {
  name = "${var.resource_name_prefix}-ExecutionRolePolicy-${data.aws_region.current.region}"
  path = "/"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Effect = "Allow"
        Action = [
          "ec2:AssignPrivateIpAddresses",
          "ec2:CreateNetworkInterface",
          "ec2:CreateNetworkInterfacePermission",
          "ec2:DeleteNetworkInterface",
          "ec2:DeleteNetworkInterfacePermission",
          "ec2:ModifyNetworkInterfaceAttribute",
          "ec2:UnassignPrivateIpAddresses"
        ]
        Resource = [
          "${local.ec2_arn_prefix}:instance/*",
          "${local.ec2_arn_prefix}:network-interface/*",
          "${local.ec2_arn_prefix}:vpc/${var.vpc_id}"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeVpcs",
          "ec2:DescribeDhcpOptions",
          "ec2:DescribeSecurityGroups",
          "ec2:DetachNetworkInterface"
        ]
        Resource = "*"

      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:GetAuthorizationToken",
          "ecr:GetDownloadUrlForLayer",
          "cloudwatch:DescribeAlarms"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "eks-auth:AssumeRoleForPodIdentity"
        ]
        Resource = var.eks_cluster_arn
      }
      ],
      !var.rig_mode ? [
        {
          Effect = "Allow"
          Action = [
            "s3:ListBucket",
            "s3:GetObject"
          ]
          Resource = [
            "arn:aws:s3:::${var.s3_bucket_name}",
            "arn:aws:s3:::${var.s3_bucket_name}/*"
          ]
        }
    ] : [])
  })

  tags = var.tags
}

# Attach Custom IAM Policy to the IAM Role
resource "aws_iam_role_policy_attachment" "sagemaker_execution_policy_attachment" {
  role       = aws_iam_role.sagemaker_execution_role.name
  policy_arn = aws_iam_policy.sagemaker_execution_policy.arn
}

# Rig IAM Policy
resource "aws_iam_policy" "rig_policy" {
  count = var.rig_mode ? 1 : 0
  name  = "${var.resource_name_prefix}-RigPolicy-${data.aws_region.current.region}"
  path  = "/"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Effect = "Allow"
          Action = [
            "s3:ListBucket",
            "s3:GetObject"
          ]
          Resource = [
            "arn:aws:s3:::${var.rig_input_s3_bucket}",
            "arn:aws:s3:::${var.rig_input_s3_bucket}/*"
          ]
        }
      ],
      var.rig_rft_lambda_access ? [
        {
          Effect   = "Allow"
          Action   = "lambda:InvokeFunction"
          Resource = "arn:aws:lambda:*:*:function:*SageMaker*"
        }
      ] : [],
      var.rig_rft_sqs_access ? [
        {
          Effect = "Allow"
          Action = [
            "sqs:SendMessage",
            "sqs:ReceiveMessage",
            "sqs:DeleteMessage"
          ]
          Resource = "arn:aws:sqs:*:*:*SageMaker*"
        }
      ] : [],
      var.rig_output_s3_bucket != null ? [
        {
          Effect = "Allow"
          Action = [
            "s3:ListBucket",
            "s3:GetObject",
            "s3:PutObject",
            "s3:DeleteObject"
          ]
          Resource = [
            "arn:aws:s3:::${var.rig_output_s3_bucket}",
            "arn:aws:s3:::${var.rig_output_s3_bucket}/*"
          ]
        }
      ] : [],
      var.gated_access ? [
        {
          Effect = "Allow"
          Action = [
            "s3:GetObject"
          ]
          Resource = [
            "arn:aws:s3:*:334772094012:accesspoint/advanced-model-customization-recipes-*/*",
            "arn:aws:s3:::advanced-model-customization-recipes*/*"
          ]
        }
      ] : []
    )
  })

  tags = var.tags
}

# Attach Rig IAM Policy to the IAM Role
resource "aws_iam_role_policy_attachment" "rig_policy_attachment" {
  count      = var.rig_mode ? 1 : 0
  role       = aws_iam_role.sagemaker_execution_role.name
  policy_arn = aws_iam_policy.rig_policy[0].arn
}

# Subnet IAM Policy 
resource "aws_iam_policy" "subnet_policy" {
  name = "${var.resource_name_prefix}-Subnet_Policy-${data.aws_region.current.region}"
  path = "/"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:AssignPrivateIpAddresses",
          "ec2:CreateNetworkInterface",
          "ec2:CreateNetworkInterfacePermission",
          "ec2:DeleteNetworkInterface",
          "ec2:DeleteNetworkInterfacePermission",
          "ec2:DetachNetworkInterface",
          "ec2:ModifyNetworkInterfaceAttribute",
          "ec2:UnassignPrivateIpAddresses"
        ]
        Resource = [
          for subnet_id in var.private_subnet_ids : "${local.ec2_arn_prefix}:subnet/${subnet_id}"
        ]
      }
    ]
  })
}

# Attach Subnet IAM Policy to the IAM Role
resource "aws_iam_role_policy_attachment" "sagemaker_subnet_policy_attachment" {
  role       = aws_iam_role.sagemaker_execution_role.name
  policy_arn = aws_iam_policy.subnet_policy.arn
}

# Security Group IAM Policy 
resource "aws_iam_policy" "sg_policy" {
  name = "${var.resource_name_prefix}-SG_Policy-${data.aws_region.current.region}"
  path = "/"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:AssignPrivateIpAddresses",
          "ec2:CreateNetworkInterface",
          "ec2:CreateNetworkInterfacePermission",
          "ec2:DeleteNetworkInterface",
          "ec2:DeleteNetworkInterfacePermission",
          "ec2:DetachNetworkInterface",
          "ec2:ModifyNetworkInterfaceAttribute",
          "ec2:UnassignPrivateIpAddresses"
        ]
        Resource = [
          "${local.ec2_arn_prefix}:security-group/${var.security_group_id}"
        ]
      }
    ]
  })
}

# Attach Security Group IAM Policy to the IAM Role
resource "aws_iam_role_policy_attachment" "sagemaker_sg_policy_attachment" {
  role       = aws_iam_role.sagemaker_execution_role.name
  policy_arn = aws_iam_policy.sg_policy.arn
}

# Cluster IAM Role for Karpenter Autoscaling
resource "aws_iam_role" "karpenter_role" {
  count = !var.rig_mode && var.karpenter_autoscaling ? 1 : 0
  name  = "${var.resource_name_prefix}-SMHP-Karpenter-Role-${data.aws_region.current.region}"
  path  = "/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "hyperpod.sagemaker.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = var.tags
}

# Karpenter Custom IAM Policy
resource "aws_iam_policy" "karpenter_policy" {
  count = !var.rig_mode && var.karpenter_autoscaling ? 1 : 0
  name  = "${var.resource_name_prefix}-SMHP-Karpenter-Policy-${data.aws_region.current.region}"
  path  = "/"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sagemaker:BatchAddClusterNodes",
          "sagemaker:BatchDeleteClusterNodes"
        ]
        Resource = "arn:aws:sagemaker:*:*:cluster/*"
        Condition = {
          StringEquals = {
            "aws:ResourceAccount" = "$${aws:PrincipalAccount}"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "kms:CreateGrant",
          "kms:DescribeKey"
        ]
        Resource = "arn:aws:kms:*:*:key/*"
        Condition = {
          StringLike = {
            "kms:ViaService" = "sagemaker.*.amazonaws.com"
          }
          Bool = {
            "kms:GrantIsForAWSResource" = "true"
          }
          "ForAllValues:StringEquals" = {
            "kms:GrantOperations" = [
              "CreateGrant",
              "Decrypt",
              "DescribeKey",
              "GenerateDataKeyWithoutPlaintext",
              "ReEncryptTo",
              "ReEncryptFrom",
              "RetireGrant"
            ]
          }
        }
      }
    ]
  })

  tags = var.tags
}

# Attach Custom IAM Policy to the IAM Role
resource "aws_iam_role_policy_attachment" "karpenter_policy_attachment" {
  count      = !var.rig_mode && var.karpenter_autoscaling ? 1 : 0
  role       = aws_iam_role.karpenter_role[0].name
  policy_arn = aws_iam_policy.karpenter_policy[0].arn
}