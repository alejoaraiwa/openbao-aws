# Aurora PostgreSQL Serverless v2 with scale-to-zero: when no OpenBao node is
# connected (cluster "down"), the database pauses after 5 minutes and only
# storage is billed. It resumes automatically (~15s) on the first connection.
data "aws_rds_engine_version" "aurora_pg" {
  engine  = "aurora-postgresql"
  version = "16"
  latest  = true
}

resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = data.aws_subnets.default.ids
}

resource "random_password" "db" {
  length  = 32
  special = false
}

# SSM Parameter Store (standard tier) is free, unlike Secrets Manager.
resource "aws_ssm_parameter" "db_password" {
  name  = "/${var.name}/db-password"
  type  = "SecureString"
  value = random_password.db.result
}

resource "aws_rds_cluster" "this" {
  cluster_identifier = var.name
  engine             = data.aws_rds_engine_version.aurora_pg.engine
  engine_version     = data.aws_rds_engine_version.aurora_pg.version
  engine_mode        = "provisioned"

  database_name   = "openbao"
  master_username = "openbao"
  master_password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  storage_encrypted      = true

  serverlessv2_scaling_configuration {
    min_capacity             = 0
    max_capacity             = 1
    seconds_until_auto_pause = 300
  }

  backup_retention_period = 1
  apply_immediately       = true

  # POC: allow `terraform destroy` to remove everything.
  deletion_protection = false
  skip_final_snapshot = true
}

resource "aws_rds_cluster_instance" "this" {
  identifier          = "${var.name}-1"
  cluster_identifier  = aws_rds_cluster.this.id
  engine              = aws_rds_cluster.this.engine
  engine_version      = aws_rds_cluster.this.engine_version
  instance_class      = "db.serverless"
  publicly_accessible = false
}

# CA bundle for sslmode=verify-full; passed to the tasks as an env var.
data "http" "rds_ca" {
  url = "https://truststore.pki.rds.amazonaws.com/${var.region}/${var.region}-bundle.pem"
}
