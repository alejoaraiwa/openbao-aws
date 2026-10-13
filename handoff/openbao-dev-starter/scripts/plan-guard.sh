#!/usr/bin/env bash
# Creates a Terraform plan and refuses it if it would update, replace or delete
# anything, unless those addresses are explicitly allowed. Creations are always
# listed for review. Use before every apply:
#
#   scripts/plan-guard.sh                      # plan.tfplan, creations only
#   ALLOW_CHANGES="aws_ecs_service.bao" scripts/plan-guard.sh
#   terraform -chdir=terraform apply plan.tfplan   # only after human approval
#
# Terraform only manages resources in its own state, so pre-existing resources
# (KMS keys, S3 buckets...) are safe unless someone imports them or adds an
# IAM/KMS/S3 *policy* resource pointing at them. This script also flags those.
set -euo pipefail

TF_DIR="${TF_DIR:-terraform}"
PLAN="${PLAN:-plan.tfplan}"
ALLOW="${ALLOW_CHANGES:-}"   # space-separated resource addresses allowed to change
read -r -a EXTRA <<<"${TF_PLAN_ARGS:-}"   # e.g. TF_PLAN_ARGS="-var-file=dev.tfvars"

terraform -chdir="$TF_DIR" plan -input=false -out="$PLAN" "${EXTRA[@]}" >/dev/null
JSON="$(terraform -chdir="$TF_DIR" show -json "$PLAN")"

echo "== Will be created"
jq -r '.resource_changes[] | select(.change.actions == ["create"]) | "  + \(.address)"' <<<"$JSON"

BAD="$(jq -r --arg allow " $ALLOW " '
  .resource_changes[]
  | select(.change.actions != ["create"] and .change.actions != ["no-op"] and .change.actions != ["read"])
  | . as $r | select(($allow | contains(" " + $r.address + " ")) | not)
  | "  \($r.change.actions | join("/")) \($r.address)"' <<<"$JSON")"

# Resources that can affect pre-existing things even when "created":
# policies attached to existing keys/buckets/roles, imports.
RISKY="$(jq -r '
  .resource_changes[]
  | select(.change.actions != ["no-op"] and .change.actions != ["read"])
  | select(.type | test("^aws_(kms_key_policy|kms_grant|s3_bucket_policy|s3_bucket_lifecycle_configuration|s3_bucket_versioning|s3_bucket_server_side_encryption_configuration|iam_role_policy_attachment|iam_user_policy|iam_user_policy_attachment)$"))
  | "  check \(.change.actions | join("/")) \(.address)"' <<<"$JSON")"
IMPORTS="$(jq -r '.resource_changes[] | select(.change.importing != null) | "  import \(.address)"' <<<"$JSON")"

if [ -n "$RISKY" ]; then
  echo "== Review: these can affect resources this project does not own"
  echo "$RISKY"
fi
if [ -n "$IMPORTS" ]; then
  echo "== REFUSED: imports of existing resources"; echo "$IMPORTS"; exit 2
fi
if [ -n "$BAD" ]; then
  echo "== REFUSED: changes/deletions not in ALLOW_CHANGES"; echo "$BAD"; exit 1
fi
echo "== OK: plan saved to $TF_DIR/$PLAN (apply it only after human approval)"
