resource "aws_kms_key" "unseal" {
  description             = "${var.name} auto-unseal"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

resource "aws_kms_alias" "unseal" {
  name          = "alias/${var.name}-unseal"
  target_key_id = aws_kms_key.unseal.key_id
}
