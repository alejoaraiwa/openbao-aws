output "url" {
  value = "https://${local.fqdn}"
}

output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "ecs_cluster" {
  value = aws_ecs_cluster.this.name
}

output "ecs_service" {
  value = aws_ecs_service.bao.name
}

output "log_group" {
  value = aws_cloudwatch_log_group.bao.name
}

output "kms_key_id" {
  value = aws_kms_key.unseal.key_id
}

output "db_endpoint" {
  value = aws_db_instance.this.address
}
