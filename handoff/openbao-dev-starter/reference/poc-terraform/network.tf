# POC: use the account's default VPC (public subnets, one per AZ) to avoid NAT
# gateways. Tasks get public IPs for egress only; their security group admits
# traffic from the load balancer and from each other, nothing else.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "OpenBao load balancer"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each          = toset(var.allowed_cidrs)
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each          = toset(var.allowed_cidrs)
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "alb_to_bao" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.bao.id
  ip_protocol                  = "tcp"
  from_port                    = 8200
  to_port                      = 8200
}

resource "aws_security_group" "bao" {
  name        = "${var.name}-nodes"
  description = "OpenBao tasks"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_vpc_security_group_ingress_rule" "bao_api_from_alb" {
  security_group_id            = aws_security_group.bao.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 8200
  to_port                      = 8200
}

# Node-to-node: request forwarding (8201) and API (8200).
resource "aws_vpc_security_group_ingress_rule" "bao_cluster" {
  security_group_id            = aws_security_group.bao.id
  referenced_security_group_id = aws_security_group.bao.id
  ip_protocol                  = "tcp"
  from_port                    = 8200
  to_port                      = 8201
}

# Egress to the internet: image pulls, KMS, CloudWatch, Secrets Manager.
resource "aws_vpc_security_group_egress_rule" "bao_all" {
  security_group_id = aws_security_group.bao.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "db" {
  name        = "${var.name}-db"
  description = "OpenBao PostgreSQL"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_vpc_security_group_ingress_rule" "db_from_bao" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = aws_security_group.bao.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}
