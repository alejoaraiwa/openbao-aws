#!/usr/bin/env bash
# Stops everything that costs money by the hour: the ECS service (tasks), the
# load balancer and its DNS record. Data stays in Aurora, which pauses itself
# 5 minutes after the last connection. Only storage + the KMS key are billed.
source "$(dirname "$0")/lib.sh"

log "Bringing the cluster down"
tf_apply_running false
log "Down. Aurora will auto-pause within ~5 minutes; run scripts/up.sh to start again."
