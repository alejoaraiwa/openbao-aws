# OpenBao DEV starter kit

Starter kit for deploying OpenBao on AWS (ECS Fargate + Aurora PostgreSQL +
KMS auto-unseal) in a company DEV account with GitHub Copilot. It packages
what a tested proof of concept learned, so Copilot starts from proven facts
instead of from scratch.

## Contents

| Path | What it is |
|---|---|
| `.github/copilot-instructions.md` | Picked up automatically by Copilot Chat in VS Code: project context and working rules |
| `.github/prompts/plan-dev-deployment.prompt.md` | Kickoff prompt: run it in Copilot Chat with `/plan-dev-deployment` |
| `docs/LEARNINGS.md` | Verified facts and pitfalls from the POC |
| `docs/DEV-TARGET.md` | Proposed DEV design (end-to-end TLS, internal NLB, private subnets) with open questions |
| `docs/POC-ARCHITECTURE.md` | POC architecture plus production and enterprise recommendations |
| `scripts/discover.sh` | Read-only inventory of the AWS account (KMS keys, S3 buckets, network, DNS, ECS, RDS, secret *names*) to `docs/ACCOUNT-INVENTORY.md` |
| `scripts/plan-guard.sh` | Terraform plan gate: lists creations, refuses updates/deletes/imports unless allowed by name |
| `reference/` | The POC's Terraform and scripts, for reference only (not deployable as is) |

## How to use

1. Create a new, empty repository for the DEV deployment (company GitHub /
   GitLab) and clone it in WSL.
2. Copy the **contents** of this folder into its root (including the hidden
   `.github/` folder), commit.
3. Open the repo in VS Code (`code .` from WSL), open Copilot Chat, choose
   **Agent** mode and a Claude model.
4. Type `/plan-dev-deployment` and press Enter. If prompt files are not
   available in your VS Code, open
   `.github/prompts/plan-dev-deployment.prompt.md` and paste its content
   (below the `---` header) into the chat.
5. It works in four gates: **discover** the account read-only (it needs an
   AWS CLI profile, e.g. `aws sso login --profile <dev>`), **tell you what it
   needs**, **agree a written plan** (`docs/DEV-PLAN.md`, nothing is created
   until you reply "plan approved"), then **roll out step by step**, each
   apply confirmed by you. Everything runs through the AWS CLI and Terraform.

The account is shared with the on-prem OpenBao (its unseal KMS key and
snapshot bucket). The instructions forbid touching anything this project did
not create; `scripts/plan-guard.sh` enforces it on every Terraform plan.

Requirements in WSL: `aws` CLI v2, `terraform` ≥ 1.10, `jq`, and
`docker`/`buildx` (or a CI pipeline) to build the image.

Make sure the setting **GitHub › Copilot › Chat › Code Generation: Use
Instruction Files** is on (default in recent VS Code), so
`.github/copilot-instructions.md` is used in every chat.

## Safety tips

- Keep VS Code's confirmation for terminal commands **on** (do not enable
  auto-approve for agent terminal commands), so you see every AWS/Terraform
  command before it runs.
- Strongest protection: use a **read-only** AWS profile (for example the
  `ReadOnlyAccess` managed policy or your company's read-only permission set)
  for the discovery and planning gates, and switch to a deploy profile only for
  the rollout. If possible, give the deploy identity an explicit deny on the
  protected KMS key and snapshot bucket ARNs.
