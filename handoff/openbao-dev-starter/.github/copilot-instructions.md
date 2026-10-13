# Copilot instructions: OpenBao on AWS (DEV)

## What this repository is

Infrastructure as code to deploy **OpenBao** (open-source fork of HashiCorp
Vault, CLI `bao`, API-compatible with Vault) in the company **AWS DEV account**:
a 3-node HA cluster on **ECS Fargate**, **Aurora PostgreSQL** storage with HA
lock, **AWS KMS auto-unseal**, an **internal NLB**, and **TLS end to end**
(TLS terminates on the OpenBao nodes, not on the load balancer).

It builds on a proof of concept that was deployed and tested. Its knowledge is
in this repo:

- `docs/LEARNINGS.md`: verified facts and pitfalls. **Read it before
  proposing or writing any Terraform, Dockerfile or OpenBao config.** Treat its
  items as requirements unless there is evidence they no longer apply.
- `docs/DEV-TARGET.md`: the proposed DEV design, with open questions marked
  **[ASK]** and the acceptance tests.
- `docs/POC-ARCHITECTURE.md`: the POC architecture plus production and
  enterprise recommendations (sizing, availability, backup/restore, KMS
  account, client IPs, on-prem recovery copy).
- `reference/poc-terraform/` and `reference/poc-scripts/`: the POC's working
  code. **Reference only, never deploy it as is**: it used a public ALB,
  public subnets and public IPs on tasks, and its `alb.tf` (public ALB + DNS)
  is not included, so it does not plan on its own. Reuse its proven pieces:
  the entrypoint that builds the config from the task IP, the Aurora parameter
  group, the IAM roles, the init and failover scripts.

## How to work

- **Ask before you assume** anything about the company environment: account,
  region, VPC and subnets, egress, DNS, certificate authority, naming, tagging,
  state backend, CI. `docs/DEV-TARGET.md` lists the open questions.
- Propose a plan and the file layout before writing code. Work in small steps
  and stop for review after each one.
- New code goes in `terraform/`, `scripts/`, `image/` (Dockerfile) and
  `docs/`. Do not edit `reference/`.
- Terraform: run `terraform fmt` and `terraform validate`, then show
  `terraform plan`. **Never run `terraform apply` or `destroy`, or any AWS
  command that creates, changes or deletes resources, without my explicit
  confirmation in the chat.** Read-only AWS commands are fine.
- Use the AWS profile / SSO session I give you; never ask for or write access
  keys into files.
- **Never print, log or commit secrets**: OpenBao root token, recovery keys,
  database passwords, TLS private keys, unseal or init output.
- Pin versions: OpenBao image and KMS plugin by digest, Terraform providers in
  `.terraform.lock.hcl`.
- After every deployment change, check the OpenBao logs in CloudWatch for
  `[ERROR]` and `[WARN]` lines, not just health checks
  (`docs/LEARNINGS.md` item 17).
- Keep costs visible: say what a change adds per month before applying it.
- Keep `docs/STATUS.md` (create it) up to date: what is done, what is next,
  decisions taken and why.

## Key technical constraints (details in docs/LEARNINGS.md)

- OpenBao 2.7.x: the `awskms` seal is an external KMS plugin; bake it into a
  custom image in ECR (no runtime download in private subnets).
- Aurora needs `rds.logical_replication = 1` for 2.7 read-enabled standbys;
  this also stops Aurora Serverless v2 from auto-pausing.
- Health check `/v1/sys/health?standbyok=true&uninitcode=200`, so all nodes get
  traffic and failover takes seconds.
- Config is built at task start from the task's own IP (`api_addr`,
  `cluster_addr`); Fargate IPs change on every replacement.
- ECS health-check grace period of at least 180 s; rolling deploys one task at
  a time.
- No `disable_mlock` in OpenBao 2.x.
