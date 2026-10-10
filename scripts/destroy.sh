#!/usr/bin/env bash
# Removes everything except the Terraform state bucket.
source "$(dirname "$0")/lib.sh"

terraform -chdir="$TF_DIR" destroy -input=false -auto-approve
aws secretsmanager delete-secret --secret-id "$INIT_SECRET" --force-delete-without-recovery >/dev/null 2>&1 || true
log "Destroyed. State bucket kept; delete it with: aws s3 rb s3://$NAME-tfstate-\$(aws sts get-caller-identity --query Account --output text) --force"
