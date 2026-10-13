---
description: Plan and build the OpenBao DEV deployment on AWS from the POC learnings
---

You are helping me deploy OpenBao to our company **AWS DEV account**, based on
a proof of concept that was already built and tested. Use Agent mode.

## Step 1: learn what was proven

Read these files fully before anything else:

1. `.github/copilot-instructions.md`
2. `docs/LEARNINGS.md`
3. `docs/DEV-TARGET.md`
4. `docs/POC-ARCHITECTURE.md`
5. `reference/poc-terraform/` (all files, especially `files/bao-entrypoint.sh`,
   `ecs.tf`, `rds.tf`) and `reference/poc-scripts/`

Then give me a summary of at most 15 lines: what the POC proved, what the DEV
target changes (end-to-end TLS, private network, internal NLB, custom image,
bigger nodes), and the 5 learnings you consider most likely to bite us.

## Step 2: ask me the open questions

Ask me every **[ASK]** item from `docs/DEV-TARGET.md` in one numbered list,
plus anything else you need. Suggest a default for each. Wait for my answers.
Do not write code yet. At least:

- AWS account, region, and the AWS CLI profile / SSO session to use.
- VPC and private subnets (3 AZs); internet egress (NAT / proxy) or VPC
  endpoints needed; which endpoints already exist.
- Who must reach OpenBao (on-prem ranges, VPN, other VPCs) and how
  (Transit Gateway, peering).
- DNS name and zone (Route 53 private hosted zone or corporate DNS).
- Certificate source for the node TLS certificate: company PKI, AWS Private
  CA, or a DEV-only CA generated with the Terraform `tls` provider.
- Client IP needs: Proxy Protocol v2 on the NLB or not.
- Terraform state backend, naming and tagging standards, permission
  boundaries or SCPs I should know about, CI/CD.
- ECR repository and image build process (local docker/buildx, CI).
- Where the init output goes (PGP-encrypted recovery keys to named people,
  or SSM SecureString) and who the key custodians are.
- Budget for DEV per month, and whether DEV may be stopped outside office
  hours.

## Step 3: propose the plan

From my answers, write `docs/DEV-DESIGN.md`: the final design (update the
`DEV-TARGET.md` table with the decisions), a component diagram (Mermaid), the
file layout of `terraform/`, `image/` and `scripts/`, the order of
implementation, a monthly cost estimate, and the acceptance tests. Wait for my
approval.

## Step 4: implement step by step

Suggested order, one step per review:

1. `image/Dockerfile` (OpenBao 2.7.x + KMS plugin, `--chmod=0755`, pinned by
   digest) and a build/push script for linux/arm64 to ECR. Verify locally
   that `bao server` starts with the plugin config before pushing.
2. Terraform foundation: providers, backend, KMS key, security groups,
   IAM roles, CloudWatch log group, ECR repo (if Terraform owns it).
3. Aurora: subnet group, cluster parameter group with
   `rds.logical_replication = 1`, cluster + writer (+ reader), DB secret.
4. TLS: certificate and key (per the chosen source) into Secrets Manager.
5. ECS: cluster, task definition (entrypoint adapted from the POC for TLS:
   write cert/key from secrets to `/tmp/tls`, `https://` api_addr, TLS
   listener, plugin `command` form), service (grace 180 s, min 66 / max 134,
   ECS Exec).
6. Internal NLB, TCP 443 → 8200, HTTPS health check, optional Proxy
   Protocol v2; DNS record.
7. Scripts: init (store the init output safely, never print it), status,
   failover test (from the POC, with its fixes), log check.
8. Run the acceptance tests in `docs/DEV-TARGET.md` and record the results in
   `docs/STATUS.md`.

For every step: show the diff, run `terraform fmt` / `validate` / `plan`,
explain the cost impact, and wait for my "apply". Never apply on your own.
