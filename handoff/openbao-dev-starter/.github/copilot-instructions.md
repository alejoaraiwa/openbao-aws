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
  enterprise recommendations.
- `reference/poc-terraform/` and `reference/poc-scripts/`: the POC's working
  code. **Reference only, never deploy it as is** (public ALB, public subnets;
  `alb.tf` is not included, so it does not plan on its own).
- `scripts/discover.sh`: read-only account inventory.
- `scripts/plan-guard.sh`: Terraform plan gate that refuses updates, deletes
  and imports unless explicitly allowed.

## This account is shared: protected resources

The DEV account **already runs things this project must not disturb**:

- **An AWS KMS key that unseals the on-prem OpenShift OpenBao DEV cluster.**
  If it is disabled, deleted, its key policy changed, or its grants removed,
  that cluster cannot unseal after a restart.
- **S3 bucket(s) holding OpenBao snapshots** uploaded from on-prem.

Rules:

1. **Never modify, re-use, tag, import or delete any resource this project did
   not create.** In particular: no changes to existing KMS keys (policy,
   grants, aliases, rotation, state), existing S3 buckets (policy, lifecycle,
   versioning, encryption, objects), existing IAM roles/users/policies,
   existing VPC route tables, security groups, DNS zones' existing records.
2. Create **new, dedicated** resources: a new KMS key for this cluster's
   unseal (never the on-prem key), new security groups, new IAM roles, and a
   new S3 bucket only if one is really needed (Aurora backups need none).
3. Prefix every resource name with the agreed project prefix (for example
   `openbao-ecs-dev-`) and tag everything (`Project`, `Owner`, `Environment`,
   `ManagedBy=terraform`) so it can never be confused with existing resources.
4. IAM policies for this project reference **only this project's ARNs**: never
   `kms:*` on `*`, never the on-prem key ARN, never the snapshot bucket ARN.
5. No account-wide settings (S3 account public access block, EBS default
   encryption, default VPC, CloudTrail, Config, GuardDuty, IAM password policy)
   without explicit approval.
6. Terraform must not `import` existing resources. Read existing ones with
   `data` sources only when the plan says so (for example the VPC and subnets).
7. Every apply goes through `scripts/plan-guard.sh`: the plan must contain only
   creations, or updates/deletes of this project's own resources that I
   approved by name (`ALLOW_CHANGES`).

## How to work: everything through the API, nothing in the console

All work is done from the terminal with the **AWS CLI and Terraform**: no
console clicking, by you or by me. The workflow has four gates; never skip
ahead:

1. **Discover (read-only).** Run `scripts/discover.sh` (or equivalent
   describe/list/get calls) and summarise what already runs in the account,
   explicitly listing the protected resources. Never read secret values,
   object contents, or call decrypt/sign APIs.
2. **Tell me what you need.** One numbered list: decisions (the **[ASK]**
   items of `docs/DEV-TARGET.md`), information, and the **IAM permissions**
   the deploying identity needs. Wait for my answers.
3. **Agree a written plan.** Write `docs/DEV-PLAN.md`: what will be created
   (resource by resource, with names), what will only be read, what will never
   be touched (protected list), costs per month, rollout steps, rollback,
   acceptance tests. **Do not create anything until I reply "plan approved".**
4. **Roll out step by step.** One step at a time: show the diff, run
   `terraform fmt`, `validate`, then `scripts/plan-guard.sh`; explain the plan
   and its cost; wait for my "apply" for that step.

Further rules:

- Read-only AWS commands (describe, list, get) are fine at any time. Any
  command that creates, changes or deletes something needs my explicit OK, and
  should go through Terraform unless there is no Terraform resource for it.
- Use the AWS profile / SSO session I give you (`AWS_PROFILE`); never ask for
  or write access keys into files.
- **Never print, log or commit secrets**: OpenBao root token, recovery keys,
  database passwords, TLS private keys, init output.
- Pin versions: OpenBao image and KMS plugin by digest, providers in
  `.terraform.lock.hcl`.
- After every deployment change, check the OpenBao logs in CloudWatch for
  `[ERROR]` and `[WARN]` lines, not just health checks (LEARNINGS item 17).
- Keep `docs/STATUS.md` up to date: done, next, decisions and why.

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
