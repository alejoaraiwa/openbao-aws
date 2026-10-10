# OpenBao on AWS: POC plan

## Goal

A low-maintenance OpenBao cluster to learn on and to prove that HA failover
works: 3 nodes, one active and two standby, with the standbys taking over when
the active node dies.

## Decisions

| Topic | Choice | Why |
|---|---|---|
| Compute | ECS on Fargate, 3 tasks across 3 AZs, ARM64, 0.5 vCPU / 1 GB | No servers or Kubernetes to run |
| Storage | RDS PostgreSQL 17, `db.t4g.micro`, single-AZ | Makes the containers stateless; AWS handles backups and patching |
| HA | OpenBao PostgreSQL backend with `ha_enabled` (lock in Postgres) | One active node; standbys forward requests to it over :8201 |
| Unseal | AWS KMS auto-unseal | Restarted nodes unseal themselves |
| Network | Default VPC, public subnets, tasks get public IPs (egress only) | No NAT gateway; SGs only let the ALB and the other nodes reach the tasks |
| TLS / DNS | ALB + ACM cert for `bao.ubts.es`; Cloudflare DNS (DNS-only, not proxied) | Free, auto-renewing cert, managed by Terraform |
| DB credentials | RDS-managed master password in Secrets Manager → `PGPASSWORD` | No passwords in code or state |
| Init output | Recovery keys + root token in Secrets Manager `openbao-poc/init` | POC convenience; for production keep these offline |
| State | S3 bucket `openbao-poc-tfstate-<account>` with S3 native locking | Survives the ephemeral session container |
| Cost guard | AWS Budget, $100/month, email alerts at 50%/80% actual and 100% forecast | No surprises. Expected cost is about $70–80/month |
| Region | `eu-west-1` | Cheapest and most complete EU region |

Notes:
- ALB health check is `/v1/sys/health?standbyok=true&uninitcode=200`, so
  standby and not-yet-initialized nodes are not killed by ECS.
- Each task builds its config at start (`terraform/files/bao-entrypoint.sh`)
  from its own IP, read from ECS task metadata (`api_addr`, `cluster_addr`).
- Postgres TLS uses `sslmode=verify-full` with the regional RDS CA bundle.

## Runbook

The SessionStart hook installs `terraform` and `aws` (`scripts/install-tools.sh`).

```bash
scripts/bootstrap.sh                         # verify creds, create state bucket, terraform init
export TF_VAR_alert_email='<budget alert email>'
terraform -chdir=terraform apply             # ~10–15 min (RDS is the slow part)
scripts/init-openbao.sh                      # init, store keys, check all 3 nodes
scripts/failover-test.sh                     # kill the active node, measure failover
scripts/destroy.sh                           # tear it all down
```

Debugging: logs are in CloudWatch `/ecs/openbao-poc`
(`aws logs tail /ecs/openbao-poc --follow`). ECS Exec is enabled.

## Status

- [x] Design agreed
- [x] Terraform + scripts written; `terraform validate` passes
- [ ] User: AWS account (paid plan), IAM user `claude-deployer` + access key
- [ ] User: Cloudflare API token (Edit zone DNS, zone `ubts.es`)
- [ ] User: env vars set in the Claude environment; budget alert email confirmed
- [ ] `scripts/bootstrap.sh`
- [ ] `terraform apply`
- [ ] `scripts/init-openbao.sh`; `https://bao.ubts.es` answers
- [ ] `scripts/failover-test.sh` passes
