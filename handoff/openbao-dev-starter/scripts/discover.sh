#!/usr/bin/env bash
# Read-only inventory of the AWS account/region, written to a Markdown report.
# Uses only describe/list/get calls. It never reads secret values, object
# contents or decrypts anything.
#
# Usage: AWS_PROFILE=<profile> AWS_REGION=<region> scripts/discover.sh [out.md]
set -uo pipefail   # no -e: one denied call must not stop the inventory

OUT="${1:-docs/ACCOUNT-INVENTORY.md}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
[ -n "$REGION" ] || { echo "Set AWS_REGION" >&2; exit 1; }
export AWS_PAGER=""
mkdir -p "$(dirname "$OUT")"

aws_q() { aws --region "$REGION" "$@" --output json 2>/dev/null || echo '"ACCESS DENIED OR ERROR"'; }
section() { printf '\n## %s\n\n' "$1" >> "$OUT"; }
table() {  # table <json> <jq producing rows as arrays> <header cells...>
  local json="$1" filter="$2"; shift 2
  if ! jq -e 'type != "string"' >/dev/null 2>&1 <<<"$json"; then
    echo "_Not readable (access denied or error)._" >> "$OUT"; return
  fi
  local rows; rows="$(jq -r "$filter | map(tostring | gsub(\"\\\\|\"; \"/\")) | \"| \" + join(\" | \") + \" |\"" <<<"$json")"
  if [ -z "$rows" ]; then echo "_None._" >> "$OUT"; return; fi
  { printf '| %s ' "$@"; echo '|'; printf '|---%.0s' "$@"; echo '|'; echo "$rows"; } >> "$OUT"
}

ID="$(aws_q sts get-caller-identity)"
{
  echo "# AWS account inventory (read-only)"
  echo
  echo "Generated $(date -u +%FT%TZ) by scripts/discover.sh."
  echo "Account: $(jq -r '.Account // "?"' <<<"$ID") · Region: $REGION · Caller: $(jq -r '.Arn // "?"' <<<"$ID")"
  echo
  echo "Resources listed here existed before this project. **Everything in the"
  echo "Protected section must not be modified, re-used or deleted.**"
} > "$OUT"

section "Protected: KMS customer-managed keys"
KEYS="$(aws_q kms list-keys)"
ALIASES="$(aws_q kms list-aliases)"
if jq -e '.Keys' >/dev/null 2>&1 <<<"$KEYS"; then
  ROWS='[]'
  for k in $(jq -r '.Keys[].KeyId' <<<"$KEYS"); do
    D="$(aws_q kms describe-key --key-id "$k")"
    jq -e '.KeyMetadata.KeyManager == "CUSTOMER"' >/dev/null 2>&1 <<<"$D" || continue
    A="$(jq -r --arg k "$k" '[.Aliases[]? | select(.TargetKeyId==$k) | .AliasName] | join(", ")' <<<"$ALIASES")"
    T="$(aws_q kms list-resource-tags --key-id "$k" | jq -r '[.Tags[]? | "\(.TagKey)=\(.TagValue)"] | join(", ")' 2>/dev/null)"
    ROWS="$(jq --argjson d "$D" --arg a "$A" --arg t "$T" '. + [[$d.KeyMetadata.KeyId, $a, $d.KeyMetadata.KeyState, $d.KeyMetadata.KeySpec, ($d.KeyMetadata.CreationDate|tostring|.[0:10]), ($d.KeyMetadata.Description // ""), $t]]' <<<"$ROWS")"
  done
  table "$ROWS" '.[]' "Key ID" "Aliases" "State" "Spec" "Created" "Description" "Tags"
  echo >> "$OUT"
  echo "Some keys are likely used to unseal existing OpenBao/Vault clusters (for example on-prem). Never change their key policy, state, rotation or aliases. Create a new, dedicated key." >> "$OUT"
else
  echo "_Not readable (access denied or error)._" >> "$OUT"
fi

section "Protected: S3 buckets"
B="$(aws_q s3api list-buckets)"
if jq -e '.Buckets' >/dev/null 2>&1 <<<"$B"; then
  ROWS='[]'
  for b in $(jq -r '.Buckets[].Name' <<<"$B"); do
    L="$(aws s3api get-bucket-location --bucket "$b" --output text 2>/dev/null || echo '?')"
    [ "$L" = "None" ] && L="us-east-1"
    T="$(aws s3api get-bucket-tagging --bucket "$b" --output json 2>/dev/null | jq -r '[.TagSet[]? | "\(.Key)=\(.Value)"] | join(", ")')"
    ROWS="$(jq --arg b "$b" --arg l "$L" --arg t "$T" '. + [[$b, $l, $t]]' <<<"$ROWS")"
  done
  table "$ROWS" '.[]' "Bucket" "Region" "Tags"
  echo >> "$OUT"
  echo "Bucket contents were not listed. Some buckets hold existing OpenBao snapshots. Never change their policy, lifecycle, versioning, encryption or contents." >> "$OUT"
else
  echo "_Not readable (access denied or error)._" >> "$OUT"
fi

section "Network: VPCs"
table "$(aws_q ec2 describe-vpcs)" '.Vpcs[] | [.VpcId, .CidrBlock, (.IsDefault|tostring), ([.Tags[]? | select(.Key=="Name") | .Value] | join(""))]' "VPC" "CIDR" "Default" "Name"

section "Network: subnets"
table "$(aws_q ec2 describe-subnets)" '.Subnets[] | [.SubnetId, .VpcId, .AvailabilityZone, .CidrBlock, (.MapPublicIpOnLaunch|tostring), .AvailableIpAddressCount, ([.Tags[]? | select(.Key=="Name") | .Value] | join(""))]' "Subnet" "VPC" "AZ" "CIDR" "Public IP on launch" "Free IPs" "Name"

section "Network: route tables (default routes)"
table "$(aws_q ec2 describe-route-tables)" '.RouteTables[] | [.RouteTableId, .VpcId, ([.Associations[]?.SubnetId // empty] | join(" ")), ([.Routes[]? | select(.DestinationCidrBlock=="0.0.0.0/0") | (.NatGatewayId // .GatewayId // .TransitGatewayId // .NetworkInterfaceId // "?")] | join(" "))]' "Route table" "VPC" "Subnets" "0.0.0.0/0 via"

section "Network: NAT gateways, Transit Gateway attachments, VPC endpoints"
table "$(aws_q ec2 describe-nat-gateways)" '.NatGateways[] | [.NatGatewayId, .VpcId, .SubnetId, .State]' "NAT gateway" "VPC" "Subnet" "State"
echo >> "$OUT"
table "$(aws_q ec2 describe-transit-gateway-attachments)" '.TransitGatewayAttachments[] | [.TransitGatewayAttachmentId, .TransitGatewayId, .ResourceType, .ResourceId, .State]' "Attachment" "TGW" "Type" "Resource" "State"
echo >> "$OUT"
table "$(aws_q ec2 describe-vpc-endpoints)" '.VpcEndpoints[] | [.VpcEndpointId, .VpcId, .ServiceName, .VpcEndpointType, .State]' "Endpoint" "VPC" "Service" "Type" "State"

section "DNS: Route 53 hosted zones"
table "$(aws_q route53 list-hosted-zones)" '.HostedZones[] | [.Id, .Name, (.Config.PrivateZone|tostring), .ResourceRecordSetCount]' "Zone" "Name" "Private" "Records"

section "Certificates: ACM and AWS Private CA"
table "$(aws_q acm list-certificates)" '.CertificateSummaryList[] | [.DomainName, .Status, .Type, .CertificateArn]' "Domain" "Status" "Type" "ARN"
echo >> "$OUT"
table "$(aws_q acm-pca list-certificate-authorities)" '.CertificateAuthorities[] | [.Arn, .Type, .Status]' "Private CA" "Type" "Status"

section "Compute and load balancing"
table "$(aws_q ecs list-clusters)" '.clusterArns[] | [.]' "ECS cluster"
echo >> "$OUT"
table "$(aws_q elbv2 describe-load-balancers)" '.LoadBalancers[] | [.LoadBalancerName, .Type, .Scheme, .VpcId, .State.Code]' "Load balancer" "Type" "Scheme" "VPC" "State"
echo >> "$OUT"
table "$(aws_q ecr describe-repositories)" '.repositories[] | [.repositoryName, .imageTagMutability, (.imageScanningConfiguration.scanOnPush|tostring)]' "ECR repo" "Tag mutability" "Scan on push"

section "Databases"
table "$(aws_q rds describe-db-clusters)" '.DBClusters[] | [.DBClusterIdentifier, .Engine, .EngineVersion, .Status, .DBClusterParameterGroup]' "Cluster" "Engine" "Version" "Status" "Param group"
echo >> "$OUT"
table "$(aws_q rds describe-db-instances)" '.DBInstances[] | [.DBInstanceIdentifier, .Engine, .DBInstanceClass, .DBInstanceStatus]' "Instance" "Engine" "Class" "Status"

section "Secrets and parameters (names only, never values)"
table "$(aws_q secretsmanager list-secrets)" '.SecretList[] | [.Name, (.KmsKeyId // "aws/secretsmanager")]' "Secret" "KMS key"
echo >> "$OUT"
table "$(aws_q ssm describe-parameters)" '.Parameters[] | [.Name, .Type]' "SSM parameter" "Type"

section "IAM roles that look related (openbao, vault, bao, kms, unseal)"
table "$(aws iam list-roles --output json 2>/dev/null || echo '"ERR"')" '.Roles[] | select(.RoleName | test("openbao|vault|bao|kms|unseal"; "i")) | [.RoleName, (.CreateDate|tostring|.[0:10])]' "Role" "Created"

section "IAM users that look related"
table "$(aws iam list-users --output json 2>/dev/null || echo '"ERR"')" '.Users[] | select(.UserName | test("openbao|vault|bao|kms|unseal|openshift"; "i")) | [.UserName, (.CreateDate|tostring|.[0:10])]' "User" "Created"

section "Who am I allowed to be? (caller policies)"
CALLER_ARN="$(jq -r '.Arn // ""' <<<"$ID")"
echo "Caller: \`$CALLER_ARN\`. If it is an SSO/assumed role, check its permission set with the account admins; required permissions are listed in the plan." >> "$OUT"

echo "Wrote $OUT" >&2
