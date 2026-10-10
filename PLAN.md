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
| Storage | Aurora PostgreSQL Serverless v2, **min 0 ACU** (scale-to-zero), max 1 ACU | Pauses itself 5 min after the last connection, so it costs nothing while down except storage |
| HA | OpenBao PostgreSQL backend with `ha_enabled` (lock in Postgres) | One active node; standbys forward requests to it over :8201 |
| Unseal | AWS KMS auto-unseal | Restarted nodes unseal themselves |
| Network | Default VPC, public subnets, tasks get public IPs (egress only) | No NAT gateway; SGs only let the ALB and the other nodes reach the tasks |
| TLS / DNS | ALB + ACM cert for `bao.ubts.es`; Cloudflare DNS (DNS-only, not proxied) | Free cert. The ALB and DNS record exist only while up |
| On/off | Terraform variable `running` (default `false`); `scripts/up.sh` / `scripts/down.sh` | Down removes the ECS service, the ALB and the DNS record; Aurora then pauses |
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
- The first connection after a pause waits ~15s for Aurora to resume;
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
- [ ] Credentials verified in a session (first attempt: AWS keys were Network secrets, Cloudflare token missing)
- [ ] Budget alert email set
- [ ] `scripts/bootstrap.sh`
- [ ] `scripts/up.sh`; `https://bao.ubts.es` answers; 3 nodes healthy
- [ ] `scripts/failover-test.sh` passes
- [ ] `scripts/down.sh`; `scripts/status.sh` shows nothing billed hourly
