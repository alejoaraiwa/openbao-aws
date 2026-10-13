#!/usr/bin/env bash
# Stops everything that costs money by the hour: the ECS service (tasks), the
# load balancer and its DNS record, then stops the Aurora cluster. Aurora can't
# auto-pause with logical replication on (needed by OpenBao 2.7 read-enabled
# standbys), so it is stopped instead. Only storage + the KMS key are billed.
# Note: AWS starts a stopped cluster again after 7 days; re-run this script.
source "$(dirname "$0")/lib.sh"

log "Bringing the cluster down"
tf_apply_running false
case "$(db_status)" in
  available)
    log "Stopping the Aurora cluster"
    aws rds stop-db-cluster --db-cluster-identifier "$NAME" >/dev/null ;;
  stopping|stopped) log "Aurora cluster already $(db_status)" ;;
  *) log "Aurora cluster is $(db_status); stop it later with: aws rds stop-db-cluster --db-cluster-identifier $NAME" ;;
esac
log "Down. Run scripts/up.sh to start again."
