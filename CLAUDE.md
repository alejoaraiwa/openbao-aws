# OpenBao on AWS (POC)

3-node OpenBao cluster on ECS Fargate with a PostgreSQL (RDS) HA backend,
KMS auto-unseal, published at https://bao.ubts.es (Cloudflare DNS).

Architecture (POC + enterprise baseline): `docs/ARCHITECTURE.md`.

Read `PLAN.md` first: it holds the design decisions, current status, and the
runbook. Keep its **Status** section up to date as work progresses.

- Terraform lives in `terraform/`; operational scripts in `scripts/`.
- Credentials come from the environment: `AWS_ACCESS_KEY_ID`,
  `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`, `CLOUDFLARE_API_TOKEN`. Never print
  them or the OpenBao root token / recovery keys.
- The container is ephemeral: state is in S3, code must be committed and pushed.
