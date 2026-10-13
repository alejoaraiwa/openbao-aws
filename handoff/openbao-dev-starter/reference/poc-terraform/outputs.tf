output "running" {
  value = var.running
}

output "url" {
  value = "https://${var.hostname}.${var.zone_name}" # POC: public ALB + DNS lived in alb.tf (not included)
}

output "ecs_cluster" {
  value = aws_ecs_cluster.this.name
}

output "ecs_service" {
  value = var.name
}

output "log_group" {
  value = aws_cloudwatch_log_group.bao.name
}

output "db_endpoint" {
  value = aws_rds_cluster.this.endpoint
}
