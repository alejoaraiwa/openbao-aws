# OpenBao on AWS: POC plan

## Goal

A low-maintenance OpenBao cluster to learn on and to prove that HA failover
works: 3 nodes, one active and two standby, with the standbys taking over when
the active node dies.

**Cost rule (from the user):** no AWS credits are available, so use as few
resources as possible and keep the cluster **down** whenever it is not in use.
Run `scripts/down.sh` at the end of every working session.

## Decisions

| Topic | Choice | Why |
|---|---|---|
| Compute | ECS on Fargate, 3 tasks across 3 AZs, ARM64, 0.25 vCPU / 0.5 GB (the minimum size) | No servers; cheapest Fargate size |
| Storage | Aurora PostgreSQL Serverless v2, min 0 ACU, max 1 ACU, logical replication on | Logical replication (needed by 2.7 read-enabled standbys) blocks auto-pause, so `down.sh` **stops** the cluster and `up.sh` starts it; while stopped only storage is billed |
| HA | OpenBao PostgreSQL backend with `ha_enabled` (lock in Postgres) | One active node; standbys forward requests to it over :8201 |
| Unseal | AWS KMS auto-unseal | Restarted nodes unseal themselves |
| Network | Default VPC, public subnets, tasks get public IPs (egress only) | No NAT gateway; SGs only let the ALB and the other nodes reach the tasks |
| TLS / DNS | ALB + ACM cert for `bao.ubts.es`; Cloudflare DNS (DNS-only, not proxied) | Free cert. The ALB and DNS record exist only while up |
| On/off | Terraform variable `running` (default `false`); `scripts/up.sh` / `scripts/down.sh` | Down removes the ECS service, the ALB and the DNS record, then stops Aurora (AWS restarts a stopped cluster after 7 days: re-run `down.sh`) |
| Secrets | DB password and init output (recovery keys, root token) in **SSM Parameter Store** SecureString | Free, unlike Secrets Manager. For production keep the init output offline |
| State | S3 bucket `openbao-poc-tfstate-<account>` with S3 native locking | Survives the ephemeral session container |
| Cost guard | AWS Budget, $10/month, when `alert_email` is set | Email alerts at 50%/80% actual and 100% forecast |
| Region | `eu-west-1` | Cheapest and most complete EU region |

Rough cost (eu-west-1 list prices, to be confirmed against the bill):
- **Up:** ~$0.15–0.20/hour (Fargate ~$0.03, Aurora ~$0.07, ALB ~$0.03, public IPv4 ~$0.03).
- **Down:** ~$1–1.5/month (KMS key $1, Aurora storage, S3, logs).

Notes:
- ALB health check is `/v1/sys/health?standbyok=true&uninitcode=200`, so
  standby and not-yet-initialized nodes are not killed by ECS.
- Each task builds its config at start (`terraform/files/bao-entrypoint.sh`)
  from its own IP, read from ECS task metadata (`api_addr`, `cluster_addr`).
- Postgres TLS uses `sslmode=verify-full` with the regional RDS CA bundle.
- The first connection after a pause waits for Aurora to resume (measured up to ~80s;
  ECS health-check grace period is 180s);
  `max_connect_retries = 0` makes OpenBao retry until it is up.

## Credentials

Plain **environment variables** in the Claude environment (not Network secrets:
AWS signs requests locally, so a proxy placeholder cannot work):
`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION=eu-west-1`,
`CLOUDFLARE_API_TOKEN`. New values only reach a new session.

## Runbook

The SessionStart hook installs `terraform` and `aws` (`scripts/install-tools.sh`).

```bash
scripts/bootstrap.sh       # once per session: verify creds, state bucket, terraform init
scripts/up.sh              # start (first run creates everything, ~15 min; later ~5 min) + init/health check
scripts/status.sh          # what is running / billing
scripts/failover-test.sh   # kill the active node, measure failover
scripts/down.sh            # stop everything billed hourly (do this after every session)
scripts/destroy.sh         # remove everything for good
```

Budget alerts: set `alert_email` in `terraform/poc.auto.tfvars` (committed).

Debugging: logs are in CloudWatch `/ecs/openbao-poc`
(`aws logs tail /ecs/openbao-poc --follow`). ECS Exec is enabled.

## Status

- [x] Design agreed (3 nodes, minimum cost, on/off switch)
- [x] Terraform + scripts written; `terraform validate` passes
- [x] User: AWS account + `claude-deployer` access key
- [x] Credentials verified in a session (2026-10-10: AWS keys are real env vars, STS ok as `claude-deployer`; Cloudflare token sees zone `ubts.es`)
- [x] Budget alert email set (2026-10-10: `openbao-poc-monthly`, $10/month, alerts to the address in `terraform/poc.auto.tfvars`)
- [x] `scripts/bootstrap.sh` (state bucket created, `terraform init` ok)
- [x] `scripts/up.sh`; `https://bao.ubts.es` answers; 3 nodes healthy (2026-10-10, after pinning
      OpenBao to 2.6.4: in 2.7.x the awskms seal is an external plugin, so 2.7.1 crash-looped
      with "unknown wrapper: awskms". Moving to the plugin is a possible follow-up)
- [x] `scripts/failover-test.sh` passes (2026-10-10: active node stopped, standby took over,
      91 reads through the ALB during the 90s test, 0 failed; ECS back to 3 tasks within 30s)
- [x] Upgraded to OpenBao 2.7.1 with the AWS KMS seal as an external plugin
      (`ghcr.io/openbao/openbao-plugin-kms-aws:v0.1.0`, pinned by digest, downloaded at
      every task start into `/tmp/plugins`). Rolling ECS deploy, one node at a time; data
      kept. Aurora snapshot `openbao-poc-pre-2-7-upgrade` taken before (deleted 2026-10-10). Failover on 2.7.1: 94 reads, 1 failed
- [ ] Cost Explorer: `claude-deployer` gets AccessDenied ("User not enabled for cost explorer
      access"); enable IAM access to billing in the account settings to check spend from here
- [x] `scripts/down.sh`; `scripts/status.sh` shows nothing billed hourly (2026-10-10: ECS service,
      ALB and DNS record removed; Aurora paused at 0 ACU)
- [x] Architecture + production recommendation documented: `docs/ARCHITECTURE.md`
      (also shared as a Claude Doc)
- [x] 2026-10-13: fixed OpenBao 2.7 standby errors (`wal_level must be set to 'logical'`,
      ~6/s): Aurora cluster parameter group with `rds.logical_replication = 1` + writer
      reboot. Standbys now run in read-enabled mode; read-after-write through the ALB OK.
      ECS health-check grace 60s -> 180s (Aurora resume took ~80s and a task was replaced)
- [x] Aurora does NOT auto-pause with logical replication on (stayed at 0.5 ACU, ~$50/month;
      AWS documents this). `down.sh` now stops the cluster, `up.sh` starts it (+ a few minutes)
