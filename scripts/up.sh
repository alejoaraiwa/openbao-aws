#!/usr/bin/env bash
# Starts the cluster: load balancer, DNS record and 3 OpenBao tasks. The
# Aurora cluster is started first if scripts/down.sh stopped it. Initializes OpenBao the
# first time, then waits until all nodes are healthy.
source "$(dirname "$0")/lib.sh"

log "Bringing the cluster up"
case "$(db_status)" in
  stopping)
    log "Aurora is still stopping; waiting"
    until [ "$(db_status)" = stopped ]; do sleep 15; done ;&
  stopped)
    log "Starting the Aurora cluster (a few minutes)"
    aws rds start-db-cluster --db-cluster-identifier "$NAME" >/dev/null
    aws rds wait db-cluster-available --db-cluster-identifier "$NAME" ;;
esac
tf_apply_running true
"$REPO_ROOT/scripts/init-openbao.sh"
log "Up: $(tf_out url)   (run scripts/down.sh when you are done)"
