#!/usr/bin/env bash
# Shows whether the cluster is up and what is currently running/billing.
source "$(dirname "$0")/lib.sh"

echo "terraform running = $(tf_out running)"
aws ecs describe-services --cluster "$NAME" --services "$NAME" \
  --query 'services[?status==`ACTIVE`].{service:serviceName,desired:desiredCount,running:runningCount}' --output table
aws elbv2 describe-load-balancers --names "$NAME" --query 'LoadBalancers[0].State.Code' --output text 2>/dev/null \
  | sed 's/^/load balancer: /' || echo "load balancer: none"
echo "aurora cluster: $(db_status)   (stopped = no compute billed)"
# ServerlessDatabaseCapacity = 0 means the database is paused.
if [ "$(db_status)" = available ]; then aws cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name ServerlessDatabaseCapacity \
  --dimensions Name=DBClusterIdentifier,Value="$NAME" --statistics Maximum --period 300 \
  --start-time "$(date -u -d '-10 min' +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" \
  --query 'sort_by(Datapoints,&Timestamp)[-1].Maximum' --output text | sed 's/^/aurora ACUs (0 = paused): /'
fi
