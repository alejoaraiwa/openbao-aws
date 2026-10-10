resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = data.aws_subnets.default.ids
}

resource "aws_db_instance" "this" {
  identifier     = var.name
  engine         = "postgres"
  engine_version = "17"
  instance_class = var.db_instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "openbao"
  username = "openbao"
  # RDS generates the password and keeps it in Secrets Manager.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period    = 1
  auto_minor_version_upgrade = true
  apply_immediately          = true

  # POC: allow `terraform destroy` to remove everything.
  deletion_protection = false
  skip_final_snapshot = true
}

# CA bundle for sslmode=verify-full; passed to the tasks as an env var.
data "http" "rds_ca" {
  url = "https://truststore.pki.rds.amazonaws.com/${var.region}/${var.region}-bundle.pem"
}
