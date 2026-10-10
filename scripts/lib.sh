# Shared helpers; sourced by the other scripts.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"
NAME="openbao-poc"
INIT_SECRET="$NAME/init"
export AWS_REGION="${AWS_REGION:-eu-west-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_PAGER=""

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

tf_out() { terraform -chdir="$TF_DIR" output -raw "$1"; }

root_token() {
  aws secretsmanager get-secret-value --secret-id "$INIT_SECRET" \
    --query SecretString --output text | jq -r .root_token
}
