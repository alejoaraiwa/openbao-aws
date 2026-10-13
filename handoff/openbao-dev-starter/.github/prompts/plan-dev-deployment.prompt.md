---
description: Discover the DEV account, agree a plan, then build OpenBao on AWS from the POC learnings
---

You are helping me deploy OpenBao to our company **AWS DEV account**, based on
a proof of concept that was already built and tested. Use Agent mode. Do
everything through the AWS CLI and Terraform; I will not click in the console.

**The account is shared.** It already holds the KMS key that unseals our
on-prem OpenShift OpenBao DEV cluster and S3 bucket(s) with OpenBao snapshots.
Nothing we do may modify, reuse or delete them. **Nothing may be made public**
(internet-facing, `0.0.0.0/0` ingress, public IPs, public buckets or
policies) unless I explicitly ask, you warn me, and I confirm. Follow the
rules in `.github/copilot-instructions.md` strictly.

## Step 1: learn what was proven (no AWS calls yet)

Read fully: `.github/copilot-instructions.md`, `docs/LEARNINGS.md`,
`docs/DEV-TARGET.md`, `docs/POC-ARCHITECTURE.md`, `reference/` (especially
`poc-terraform/files/bao-entrypoint.sh`, `ecs.tf`, `rds.tf`) and `scripts/`.

Summarise in at most 15 lines: what the POC proved, what DEV changes (end-to-end
TLS, private network, internal NLB, custom image, bigger nodes), and the 5
learnings most likely to bite us.

## Step 2: discover the account (read-only)

Ask me for the AWS profile and region, then run:

```bash
AWS_PROFILE=<profile> AWS_REGION=<region> scripts/discover.sh docs/ACCOUNT-INVENTORY.md
```

Then go deeper with read-only calls where useful (for example the key policy
and tags of each KMS key, `aws kms get-key-policy`; bucket tags and region;
which subnets are private; where 0.0.0.0/0 routes; existing VPC endpoints and
hosted zones). **Never** read secret values or bucket objects, never call
decrypt/encrypt/sign.

Report:
- what runs in the account today (one short table);
- the **protected resources**, with IDs/ARNs: the on-prem unseal KMS key(s),
  the snapshot bucket(s), and anything else that looks in use. Ask me to
  confirm the list;
- candidate VPC/subnets for the cluster and how they reach the internet or
  AWS services;
- anything that would block or complicate the DEV target.

## Step 3: tell me what you need

One numbered list, each item with your suggested default:
- every **[ASK]** item in `docs/DEV-TARGET.md`;
- the resource name prefix and tags to use;
- the IAM permissions the deploying identity needs (and whether my current
  identity has them, from what you could check read-only);
- anything else you need to know or have.

Wait for my answers.

## Step 4: agree the plan

Write `docs/DEV-PLAN.md`:
1. Final design (the `DEV-TARGET.md` table with decisions filled in) and a
   Mermaid component diagram.
2. **Will be created**: every resource with its name.
3. **Will only be read**: existing resources referenced via `data` sources.
4. **Will never be touched**: the protected list from step 2.
   Also state explicitly that nothing is public: every network entry point,
   who can reach it (CIDRs / security groups), and that the plan contains no
   public exposure.
5. Monthly cost estimate.
6. Rollout steps (below) with a rollback for each, and how to remove
   everything this project created without touching anything else.
7. Acceptance tests (from `DEV-TARGET.md`).

Then stop and wait. Do not create anything until I reply **"plan approved"**.

## Step 5: roll out step by step

Suggested order, one step per review:

1. `image/Dockerfile` (OpenBao 2.7.x + KMS plugin, `--chmod=0755`, pinned by
   digest) and a build/push script for linux/arm64 to a new ECR repo. Verify
   locally that `bao server` starts with the plugin config before pushing.
2. Terraform foundation: providers, backend, **new** KMS key and alias for this
   cluster, security groups, IAM roles scoped to this project's ARNs, log
   group, ECR repo.
3. Aurora: subnet group, cluster parameter group with
   `rds.logical_replication = 1`, cluster + writer (+ reader), DB secret.
4. TLS: certificate and key (per the chosen source) into Secrets Manager.
5. ECS: cluster, task definition (entrypoint adapted from the POC for TLS:
   write cert/key from secrets to `/tmp/tls`, `https://` api_addr, TLS
   listener, plugin `command` form), service (grace 180 s, 66/134 %, ECS
   Exec).
6. Internal NLB, TCP 443 → 8200, HTTPS health check, optional Proxy
   Protocol v2; DNS record.
7. Scripts: init (store the init output safely, never print it), status,
   failover test (from the POC, with its fixes), log check.
8. Acceptance tests; results in `docs/STATUS.md`.

For every step: show the diff, run `terraform fmt` and `validate`, then
`scripts/plan-guard.sh`, explain the plan and its cost, and wait for my
"apply". Never apply on your own. After applying, re-run the read-only checks
to confirm the protected resources are unchanged.
