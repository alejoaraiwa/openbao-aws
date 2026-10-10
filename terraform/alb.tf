data "cloudflare_zone" "this" {
  filter = {
    name = var.zone_name
  }
}

locals {
  fqdn = "${var.hostname}.${var.zone_name}"
}

resource "aws_acm_certificate" "this" {
  domain_name       = local.fqdn
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "cloudflare_dns_record" "acm_validation" {
  for_each = {
    for o in aws_acm_certificate.this.domain_validation_options : o.domain_name => o
  }

  zone_id = data.cloudflare_zone.this.zone_id
  name    = trimsuffix(each.value.resource_record_name, ".")
  type    = each.value.resource_record_type
  content = trimsuffix(each.value.resource_record_value, ".")
  ttl     = 300
  proxied = false
  comment = "ACM validation for ${local.fqdn} (terraform: ${var.name})"
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in cloudflare_dns_record.acm_validation : r.name]
}

# Everything below exists only while var.running is true: an idle ALB and its
# public IPs are the main standing cost.
resource "aws_lb" "this" {
  count = var.running ? 1 : 0

  name               = var.name
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.default.ids
}

resource "aws_lb_target_group" "bao" {
  count = var.running ? 1 : 0

  name                 = var.name
  port                 = 8200
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = data.aws_vpc.default.id
  deregistration_delay = 10

  health_check {
    # Standbys answer 200 (they forward to the active node). Uninitialized
    # nodes also answer 200 so ECS doesn't kill them before `init` runs.
    path                = "/v1/sys/health?standbyok=true&uninitcode=200"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "https" {
  count = var.running ? 1 : 0

  load_balancer_arn = aws_lb.this[0].arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.this.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.bao[0].arn
  }
}

resource "aws_lb_listener" "http" {
  count = var.running ? 1 : 0

  load_balancer_arn = aws_lb.this[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "cloudflare_dns_record" "bao" {
  count = var.running ? 1 : 0

  zone_id = data.cloudflare_zone.this.zone_id
  name    = local.fqdn
  type    = "CNAME"
  content = aws_lb.this[0].dns_name
  ttl     = 300
  proxied = false
  comment = "OpenBao POC load balancer (terraform: ${var.name})"
}
