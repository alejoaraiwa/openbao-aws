# POC reference code (do not deploy as is)

Working code from the proof of concept, kept for reference. It deployed
successfully and passed failover and upgrade tests, but it is shaped for a
cheap personal POC:

- public subnets, public IPs on tasks, an internet-facing ALB with TLS ending
  on the ALB (plain HTTP to the nodes);
- the KMS plugin downloaded from ghcr.io at every start;
- Aurora Serverless v2 with min 0 ACU and an on/off switch (`var.running`).

Not included: `alb.tf` (public ALB, ACM certificate, public DNS) and the budget
file. `ecs.tf` therefore references `aws_lb_target_group.bao` and
`aws_lb_listener.https`, which do not exist here, so this folder does not
`terraform plan` on its own.

Most reusable pieces:

| File | Why |
|---|---|
| `poc-terraform/files/bao-entrypoint.sh` | Builds the OpenBao config at start from the task IP (ECS metadata v4); plugin + seal + PostgreSQL TLS config |
| `poc-terraform/rds.tf` | Aurora cluster, cluster parameter group with `rds.logical_replication = 1`, RDS CA bundle for `verify-full` |
| `poc-terraform/ecs.tf` | Task/execution roles, task definition, service settings (grace 180 s, 66/134 %) |
| `poc-terraform/kms.tf` | Unseal key |
| `poc-scripts/init-openbao.sh` | Init with recovery keys, stores output without printing it |
| `poc-scripts/failover-test.sh` | Stops the active task while probing reads; reports failed requests |
