#!/usr/bin/env bash
# One-time setup: verify credentials, create the Terraform state bucket,
# and run `terraform init` against it. Safe to re-run.
source "$(dirname "$0")/lib.sh"

: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID is not set (add it to the Claude environment)}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY is not set}"
: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN is not set}"

log "Checking AWS credentials"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" \
  || die "AWS credentials rejected"
log "AWS account $ACCOUNT_ID, region $AWS_REGION"

log "Checking Cloudflare token and zone"
ZONE_NAME="${ZONE_NAME:-ubts.es}"
zones="$(curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones?name=$ZONE_NAME")" || die "Cloudflare API call failed"
[ "$(jq -r '.result | length' <<<"$zones")" = "1" ] \
  || die "Cloudflare token cannot see zone $ZONE_NAME"
log "Cloudflare zone $ZONE_NAME ok"

if ! aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text | grep -q '^vpc-'; then
  die "No default VPC in $AWS_REGION. Create one with: aws ec2 create-default-vpc"
fi

BUCKET="$NAME-tfstate-$ACCOUNT_ID"
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  log "State bucket $BUCKET exists"
else
  log "Creating state bucket $BUCKET"
  aws s3api create-bucket --bucket "$BUCKET" \
    --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null
  aws s3api put-bucket-versioning --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled
  aws s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
fi

cat > "$TF_DIR/backend.hcl" <<HCL
bucket       = "$BUCKET"
key          = "$NAME/terraform.tfstate"
region       = "$AWS_REGION"
use_lockfile = true
encrypt      = true
HCL

terraform -chdir="$TF_DIR" init -input=false -reconfigure -backend-config=backend.hcl
log "Bootstrap complete"
