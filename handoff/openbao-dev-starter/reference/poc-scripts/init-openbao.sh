#!/usr/bin/env bash
# Initializes OpenBao once the cluster is up, stores the recovery keys and root
# token in SSM Parameter Store ($INIT_PARAM, SecureString), and checks every
# node is healthy.
source "$(dirname "$0")/lib.sh"

URL="$(tf_out url)"
TG_ARN="$(aws elbv2 describe-target-groups --names "$NAME" --query 'TargetGroups[0].TargetGroupArn' --output text)"

log "Waiting for $URL to answer"
for _ in $(seq 1 90); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "$URL/v1/sys/health?uninitcode=200&standbyok=true" || true)"
  [ "$code" = "200" ] && break
  sleep 10
done
[ "$code" = "200" ] || die "OpenBao never became reachable at $URL (last HTTP $code)"

if [ "$(curl -fsS "$URL/v1/sys/init" | jq -r .initialized)" = "true" ]; then
  log "Already initialized"
else
  log "Initializing (3 recovery shares, threshold 2)"
  umask 077
  OUT="$REPO_ROOT/.init-output.json"   # gitignored; removed once stored in AWS
  curl -fsS -X PUT -d '{"recovery_shares":3,"recovery_threshold":2}' "$URL/v1/sys/init" > "$OUT"
  aws ssm put-parameter --name "$INIT_PARAM" --type SecureString --overwrite \
    --description "OpenBao POC recovery keys and root token" \
    --value "file://$OUT" >/dev/null
  rm -f "$OUT"
  log "Recovery keys + root token stored in SSM Parameter Store: $INIT_PARAM"
fi

log "Waiting for all targets to be healthy and unsealed"
for _ in $(seq 1 60); do
  healthy="$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text)"
  sealed="$(curl -s "$URL/v1/sys/seal-status" | jq -r .sealed)"
  [ "$healthy" -ge 3 ] && [ "$sealed" = "false" ] && break
  sleep 10
done
log "Healthy targets: $healthy"

TOKEN="$(root_token)"
curl -fsS -H "X-Vault-Token: $TOKEN" "$URL/v1/sys/leader" | jq '{ha_enabled, is_self, leader_address}'
curl -fsS -H "X-Vault-Token: $TOKEN" "$URL/v1/sys/ha-status" | jq '[.nodes[] | {hostname, api_address, active_node}]'
