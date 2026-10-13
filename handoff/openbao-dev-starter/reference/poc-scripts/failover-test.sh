#!/usr/bin/env bash
# Kills the active OpenBao node while reading a secret through the load balancer
# twice a second, then reports how long the cluster took to fail over.
source "$(dirname "$0")/lib.sh"

URL="$(tf_out url)"
CLUSTER="$(tf_out ecs_cluster)"
SERVICE="$(tf_out ecs_service)"
TOKEN="$(root_token)"
H=(-H "X-Vault-Token: $TOKEN")

# Test data.
if ! curl -fsS "${H[@]}" "$URL/v1/sys/mounts" | jq -e '."secret/"' >/dev/null; then
  curl -fsS "${H[@]}" -X POST -d '{"type":"kv","options":{"version":"2"}}' "$URL/v1/sys/mounts/secret"
fi
curl -fsS "${H[@]}" -X POST -d '{"data":{"hello":"world"}}' "$URL/v1/secret/data/failover-test" >/dev/null

leader_ip() { curl -fsS "${H[@]}" "$URL/v1/sys/leader" | jq -r .leader_address | sed -E 's#https?://([^:]+):.*#\1#'; }

OLD_IP="$(leader_ip)"
TASKS="$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" --desired-status RUNNING --query taskArns --output text)"
# shellcheck disable=SC2086
TASK="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks $TASKS --output json | jq -r --arg ip "$OLD_IP" \
  '.tasks[] | select(any(.attachments[].details[]; .name=="privateIPv4Address" and .value==$ip)) | .taskArn')"
[ -n "$TASK" ] || die "Could not find the ECS task for active node $OLD_IP"
log "Active node: $OLD_IP (${TASK##*/})"

LOG="$(mktemp)"
( end=$((SECONDS + 90))
  while [ $SECONDS -lt $end ]; do
    # `|| true`: a failed request (curl prints 000) must not end the probe under set -e.
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "${H[@]}" "$URL/v1/secret/data/failover-test" || true)"
    echo "$(date +%s.%N) $code" >> "$LOG"
    sleep 0.5
  done ) &
PROBE=$!

sleep 5
log "Stopping active task"
aws ecs stop-task --cluster "$CLUSTER" --task "$TASK" --reason "failover test" >/dev/null

NEW_IP="$OLD_IP"
for _ in $(seq 1 120); do
  NEW_IP="$(leader_ip 2>/dev/null || echo "$OLD_IP")"
  # During the election there is no leader yet (leader_address is empty/null).
  [[ "$NEW_IP" =~ ^[0-9.]+$ ]] && [ "$NEW_IP" != "$OLD_IP" ] && break
  sleep 0.5
done
log "New active node: $NEW_IP"

wait "$PROBE"
total="$(wc -l < "$LOG")"
failed="$(awk '$2 != "200"' "$LOG" | wc -l)"
outage="$(awk '$2 != "200" { if (!s) s=$1; e=$1 } END { if (s) printf "%.1f", e - s; else print 0 }' "$LOG")"
rm -f "$LOG"

log "Requests: $total, failed: $failed, failure window: ${outage}s"
log "ECS will now start a replacement task; running count:"
sleep 30
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].{desired:desiredCount,running:runningCount}' --output table
