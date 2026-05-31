data "aws_vpc_security_group_rules" "existing" {
  count = var.create_new_sg ? 0 : 1
  filter {
    name   = "group-id"
    values = [var.existing_security_group_id]
  }
}

# Get VPC CIDR for VPC endpoint ingress rule
data "aws_vpc" "selected" {
  id = var.vpc_id
}

# Get details for each individual rule
data "aws_vpc_security_group_rule" "rule" {
  for_each               = var.create_new_sg ? toset([]) : toset(try(data.aws_vpc_security_group_rules.existing[0].ids, []))
  security_group_rule_id = each.key
}

locals {
  security_group_id = var.create_new_sg ? aws_security_group.no_ingress[0].id : var.existing_security_group_id

  # Get all rule IDs for the security group
  rule_ids = var.create_new_sg ? [] : data.aws_vpc_security_group_rules.existing[0].ids

  # Get individual rules
  rules = var.create_new_sg ? [] : [
    for id in local.rule_ids : {
      id   = id
      rule = data.aws_vpc_security_group_rule.rule[id]
    }
  ]

  # Check for specific rules
  has_intra_sg_ingress = var.create_new_sg ? false : (
    length([
      for r in local.rules : r
      if !r.rule.is_egress &&
      r.rule.ip_protocol == "-1" &&
      r.rule.from_port == -1 &&
      r.rule.to_port == -1 &&
      r.rule.referenced_security_group_id == var.existing_security_group_id
    ]) > 0
  )

  has_fsx_lustre_ingress_988 = var.create_new_sg ? false : (
    length([
      for r in local.rules : r
      if !r.rule.is_egress &&
      r.rule.ip_protocol == "tcp" &&
      r.rule.from_port == 988 &&
      r.rule.to_port == 988 &&
      r.rule.referenced_security_group_id == var.existing_security_group_id
    ]) > 0
  )

  has_fsx_lustre_ingress_1018_1023 = var.create_new_sg ? false : (
    length([
      for r in local.rules : r
      if !r.rule.is_egress &&
      r.rule.ip_protocol == "tcp" &&
      r.rule.from_port == 1018 &&
      r.rule.to_port == 1023 &&
      r.rule.referenced_security_group_id == var.existing_security_group_id
    ]) > 0
  )

  has_vpc_endpoint_https_ingress = var.create_new_sg ? false : (
    length([
      for r in local.rules : r
      if !r.rule.is_egress &&
      r.rule.ip_protocol == "tcp" &&
      r.rule.from_port == 443 &&
      r.rule.to_port == 443 &&
      r.rule.cidr_ipv4 == data.aws_vpc.selected.cidr_block
    ]) > 0
  )

  has_intra_sg_egress = var.create_new_sg ? false : (
    length([
      for r in local.rules : r
      if r.rule.is_egress &&
      r.rule.ip_protocol == "-1" &&
      r.rule.from_port == -1 &&
      r.rule.to_port == -1 &&
      r.rule.referenced_security_group_id == var.existing_security_group_id
    ]) > 0
  )

  has_internet_egress = var.create_new_sg ? false : (
    length([
      for r in local.rules : r
      if r.rule.is_egress &&
      r.rule.ip_protocol == "-1" &&
      r.rule.from_port == -1 &&
      r.rule.to_port == -1 &&
      r.rule.cidr_ipv4 == "0.0.0.0/0"
    ]) > 0
  )
}

resource "aws_security_group" "no_ingress" {
  count = var.create_new_sg ? 1 : 0

  name        = "${var.resource_name_prefix}-no-ingress-sg"
  description = "Security group with no ingress rule"
  vpc_id      = var.vpc_id

  tags = merge(
    {
      Name = "${var.resource_name_prefix}-no-ingress-sg"
    },
    var.tags
  )
}

resource "aws_vpc_security_group_ingress_rule" "intra_sg_ingress" {
  count = var.create_new_sg || !local.has_intra_sg_ingress ? 1 : 0

  description                  = "Allow traffic within the security group"
  from_port                    = -1
  to_port                      = -1
  ip_protocol                  = "-1"
  security_group_id            = local.security_group_id
  referenced_security_group_id = local.security_group_id
}

resource "aws_vpc_security_group_egress_rule" "intra_sg_egress" {
  count = var.create_new_sg || !local.has_intra_sg_egress ? 1 : 0

  description                  = "Allow traffic within the security group"
  from_port                    = -1
  to_port                      = -1
  ip_protocol                  = "-1"
  security_group_id            = local.security_group_id
  referenced_security_group_id = local.security_group_id
}

resource "aws_vpc_security_group_egress_rule" "internet_egress" {
  count = var.create_new_sg || !local.has_internet_egress ? 1 : 0

  description       = "Allow traffic to internet"
  from_port         = -1
  to_port           = -1
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  security_group_id = local.security_group_id
}

resource "aws_vpc_security_group_ingress_rule" "fsx_lustre_ingress_988" {
  count = var.create_new_sg || !local.has_fsx_lustre_ingress_988 ? 1 : 0

  description                  = "Allows Lustre traffic between FSx for Lustre file servers and Lustre clients"
  from_port                    = 988
  to_port                      = 988
  ip_protocol                  = "tcp"
  security_group_id            = local.security_group_id
  referenced_security_group_id = local.security_group_id
}

resource "aws_vpc_security_group_ingress_rule" "fsx_lustre_ingress_1018_1023" {
  count = var.create_new_sg || !local.has_fsx_lustre_ingress_1018_1023 ? 1 : 0

  description                  = "Allows Lustre traffic between FSx for Lustre file servers and Lustre clients"
  from_port                    = 1018
  to_port                      = 1023
  ip_protocol                  = "tcp"
  security_group_id            = local.security_group_id
  referenced_security_group_id = local.security_group_id
}

# VPC Endpoint HTTPS Ingress Rule
resource "aws_vpc_security_group_ingress_rule" "vpc_endpoint_https" {
  count = var.create_vpc_endpoint_ingress_rule && (var.create_new_sg || !local.has_vpc_endpoint_https_ingress) ? 1 : 0

  description       = "Allow HTTPS traffic from VPC CIDR for VPC endpoints"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  cidr_ipv4         = data.aws_vpc.selected.cidr_block
  security_group_id = local.security_group_id
}

# Cilium VXLAN overlay rules
resource "aws_vpc_security_group_ingress_rule" "cilium_vxlan_ingress" {
  count = var.enable_vxlan_rule ? 1 : 0

  description                  = "Cilium VXLAN overlay traffic"
  from_port                    = 8472
  to_port                      = 8472
  ip_protocol                  = "udp"
  security_group_id            = local.security_group_id
  referenced_security_group_id = local.security_group_id
}

resource "aws_vpc_security_group_egress_rule" "cilium_vxlan_egress" {
  count = var.enable_vxlan_rule ? 1 : 0

  description                  = "Cilium VXLAN overlay traffic"
  from_port                    = 8472
  to_port                      = 8472
  ip_protocol                  = "udp"
  security_group_id            = local.security_group_id
  referenced_security_group_id = local.security_group_id
}
