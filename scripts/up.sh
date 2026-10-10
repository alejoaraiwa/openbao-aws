#!/usr/bin/env bash
# Starts the cluster: load balancer, DNS record and 3 OpenBao tasks. The
# database resumes by itself on first connection. Initializes OpenBao the
# first time, then waits until all nodes are healthy.
source "$(dirname "$0")/lib.sh"

log "Bringing the cluster up"
tf_apply_running true
"$REPO_ROOT/scripts/init-openbao.sh"
log "Up: $(tf_out url)   (run scripts/down.sh when you are done)"
