# Getting started on a work machine (WSL + VS Code + Copilot)

The only steps you must do by hand are 1 and 2. After that, open Copilot Chat
(Agent mode, Claude model) and say:

> Read GETTING-STARTED.md and help me with step 3 onwards.

## 1. Put the kit in a new work repository (by hand)

Create an empty repository on the company GitHub (for example
`openbao-aws-dev`), then in WSL:

```bash
cp /mnt/c/Users/<windows-user>/Downloads/openbao-dev-starter.zip ~/
git clone <company-repo-url> ~/openbao-aws-dev && cd ~/openbao-aws-dev
unzip -q ~/openbao-dev-starter.zip -d /tmp/kit
cp -r /tmp/kit/openbao-dev-starter/. .      # "/." also copies the hidden .github folder
chmod +x scripts/*.sh
git add . && git commit -m "OpenBao DEV starter kit" && git push
```

## 2. Open it in VS Code (by hand)

- `code .` from the repo folder (VS Code connects to WSL; install the **WSL**
  extension if asked).
- Make sure **GitHub Copilot** and **GitHub Copilot Chat** are installed in the
  WSL window ("Install in WSL").
- Settings: **Use Instruction Files** for Copilot Chat on; agent terminal
  commands **not** auto-approved.
- Copilot Chat → **Agent** mode → a **Claude** model.

## 3. Check the tools (Copilot can do this)

Required in WSL: `aws` CLI v2, `terraform` ≥ 1.10, `jq`, `unzip`, and
`docker buildx` (or a CI pipeline) for the image build.

```bash
aws --version; terraform version; jq --version; docker buildx version
```

Install what is missing (adapt to the company proxy / software catalogue; each
install needs your approval):

```bash
sudo apt-get update && sudo apt-get install -y jq unzip
# AWS CLI v2
curl -sSLo /tmp/awscli.zip https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip \
  && unzip -q /tmp/awscli.zip -d /tmp && sudo /tmp/aws/install
# Terraform (HashiCorp apt repository)
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y terraform
```

## 4. AWS access (you answer the browser login; Copilot can guide)

Ask the AWS admins for (can be done in parallel):

- a **read-only** SSO permission set for the DEV account, used for discovery
  and planning;
- later, a **deploy** role, ideally with an explicit deny on the on-prem
  unseal KMS key and the snapshot bucket(s), and no permission to make things
  public.

Then:

```bash
aws configure sso --profile dev-readonly   # SSO start URL, region, DEV account, read-only role
aws sso login --profile dev-readonly       # opens the browser
aws sts get-caller-identity --profile dev-readonly
```

## 5. Start the guided deployment

In Copilot Chat run `/plan-dev-deployment` (or paste
`.github/prompts/plan-dev-deployment.prompt.md` below its `---` header). It
discovers the account read-only, tells you what it needs, writes
`docs/DEV-PLAN.md` for your approval, and only then builds step by step.

Have these answers ready: VPC and private subnets; egress (NAT or VPC
endpoints); who must reach OpenBao (on-prem ranges, VPN); DNS name; TLS
certificate source (company PKI, AWS Private CA, or a DEV-only CA); Terraform
state location; name prefix and tags; who holds the recovery keys; monthly
budget.

Never paste secrets into the chat (tokens, keys, passwords).
