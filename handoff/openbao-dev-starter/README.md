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
5. Answer its questions, review the plan, then let it implement step by step.
   It is instructed never to apply infrastructure without your confirmation.

Make sure the setting **GitHub › Copilot › Chat › Code Generation: Use
Instruction Files** is on (default in recent VS Code), so
`.github/copilot-instructions.md` is used in every chat.
