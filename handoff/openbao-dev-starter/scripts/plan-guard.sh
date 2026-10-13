#!/usr/bin/env bash
# Creates a Terraform plan and refuses it if it would update, replace or delete
# anything, or expose anything publicly, unless those addresses are explicitly
# allowed. Creations are always listed for review. Use before every apply:
#
#   scripts/plan-guard.sh                      # plan.tfplan, creations only
#   ALLOW_CHANGES="aws_ecs_service.bao" scripts/plan-guard.sh
#   ALLOW_PUBLIC="aws_lb.x" scripts/plan-guard.sh   # ONLY after the human was
#                                                   # warned and confirmed
#   terraform -chdir=terraform apply plan.tfplan   # only after human approval
#
# Terraform only manages resources in its own state, so pre-existing resources
# (KMS keys, S3 buckets...) are safe unless someone imports them or adds an
# IAM/KMS/S3 *policy* resource pointing at them. This script also flags those.
set -euo pipefail

TF_DIR="${TF_DIR:-terraform}"
PLAN="${PLAN:-plan.tfplan}"
ALLOW="${ALLOW_CHANGES:-}"   # space-separated resource addresses allowed to change
ALLOW_PUB="${ALLOW_PUBLIC:-}"  # space-separated addresses allowed to be public (explicit human OK only)
read -r -a EXTRA <<<"${TF_PLAN_ARGS:-}"   # e.g. TF_PLAN_ARGS="-var-file=dev.tfvars"

if [ -n "${PLAN_JSON_FILE:-}" ]; then   # testing: check an existing `terraform show -json` output
  JSON="$(cat "$PLAN_JSON_FILE")"
else
  terraform -chdir="$TF_DIR" plan -input=false -out="$PLAN" "${EXTRA[@]}" >/dev/null
  JSON="$(terraform -chdir="$TF_DIR" show -json "$PLAN")"
fi

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

# Public exposure: anything created/updated that could be reachable from the
# internet or by anyone. Heuristic, errs on the side of flagging. Values unknown
# at plan time (computed) cannot be checked: review those resources by hand.
PUBLIC="$(jq -r --arg allow " $ALLOW_PUB " '
  def pub: . == "0.0.0.0/0" or . == "::/0";
  def star_principal: test("\"Principal\"\\s*:\\s*(\"\\*\"|\\{\\s*\"AWS\"\\s*:\\s*(\"\\*\"|\\[[^\\]]*\"\\*\"))");
  .resource_changes[]
  | select(any(.change.actions[]; . == "create" or . == "update"))
  | . as $r | ($r.change.after // {}) as $a
  | (if $r.type == "aws_lb" and ($a.internal != true) then "load balancer not internal (internet-facing)"
     elif $r.type == "aws_vpc_security_group_ingress_rule" and ((($a.cidr_ipv4 // "") | pub) or (($a.cidr_ipv6 // "") | pub)) then "ingress from the whole internet (\($a.cidr_ipv4 // $a.cidr_ipv6))"
     elif $r.type == "aws_security_group_rule" and $a.type == "ingress" and ([$a.cidr_blocks[]?, $a.ipv6_cidr_blocks[]?] | any(pub)) then "ingress from the whole internet"
     elif $r.type == "aws_security_group" and ([$a.ingress[]? | (.cidr_blocks[]?, .ipv6_cidr_blocks[]?)] | any(pub)) then "inline ingress from the whole internet"
     elif $r.type == "aws_ecs_service" and ([$a.network_configuration[]?.assign_public_ip] | any(. == true)) then "public IPs on ECS tasks"
     elif $r.type == "aws_instance" and $a.associate_public_ip_address == true then "public IP on an EC2 instance"
     elif ($r.type == "aws_subnet" or $r.type == "aws_default_subnet") and $a.map_public_ip_on_launch == true then "subnet that assigns public IPs"
     elif ($r.type == "aws_db_instance" or $r.type == "aws_rds_cluster_instance") and $a.publicly_accessible == true then "publicly accessible database"
     elif $r.type == "aws_s3_bucket_public_access_block" and ([$a.block_public_acls, $a.block_public_policy, $a.ignore_public_acls, $a.restrict_public_buckets] | any(. != true)) then "S3 public access block not fully on"
     elif $r.type == "aws_s3_bucket_acl" and (($a.acl // "") | test("public")) then "public S3 ACL"
     elif ($r.type | test("^aws_(s3_bucket_policy|ecr_repository_policy|kms_key|kms_key_policy|sqs_queue_policy|sns_topic_policy|secretsmanager_secret_policy|glacier_vault)$")) and (($a.policy // "") | star_principal) then "resource policy with Principal \"*\" (check its conditions)"
     elif $r.type == "aws_lambda_permission" and $a.principal == "*" then "Lambda callable by anyone"
     elif $r.type == "aws_lambda_function_url" and $a.authorization_type == "NONE" then "Lambda URL without auth"
     elif ($r.type | test("^aws_(internet_gateway|egress_only_internet_gateway|eip|cloudfront_distribution|apigatewayv2_api|api_gateway_rest_api|globalaccelerator_accelerator|lightsail_.*)$")) then "internet-facing building block (\($r.type))"
     elif $r.type == "aws_route53_zone" and (($a.vpc // []) | length == 0) then "public hosted zone"
     elif $r.type == "aws_ec2_image_block_public_access" or $r.type == "aws_ebs_snapshot_block_public_access" then "account-wide public access setting"
     else empty end) as $why
  | select(($allow | contains(" " + $r.address + " ")) | not)
  | "  \($r.address): \($why)"' <<<"$JSON")"

if [ -n "$PUBLIC" ]; then
  echo "== REFUSED: possible PUBLIC EXPOSURE (needs a warning to the human and explicit"
  echo "   confirmation, then ALLOW_PUBLIC=\"<address> ...\")"
  echo "$PUBLIC"
  exit 3
fi

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
