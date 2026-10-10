#!/usr/bin/env bash
# Installs the CLIs this repo needs (terraform, aws). Idempotent; run by the
# SessionStart hook in Claude Code cloud sessions, safe to run by hand.
set -euo pipefail

TERRAFORM_VERSION="1.16.5"
BIN_DIR="/usr/local/bin"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

arch="$(uname -m)"
case "$arch" in
  x86_64) tf_arch=amd64; aws_arch=x86_64 ;;
  aarch64|arm64) tf_arch=arm64; aws_arch=aarch64 ;;
  *) echo "unsupported arch: $arch" >&2; exit 1 ;;
esac

if ! command -v terraform >/dev/null || ! terraform version | grep -q "v${TERRAFORM_VERSION}"; then
  curl -fsSL -o "$TMP/tf.zip" \
    "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${tf_arch}.zip"
  python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extract('terraform', sys.argv[2])" "$TMP/tf.zip" "$TMP"
  install -m 0755 "$TMP/terraform" "$BIN_DIR/terraform"
fi

if ! command -v aws >/dev/null; then
  curl -fsSL -o "$TMP/awscli.zip" "https://awscli.amazonaws.com/awscli-exe-linux-${aws_arch}.zip"
  python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$TMP/awscli.zip" "$TMP"
  chmod -R +x "$TMP/aws/dist" "$TMP/aws/install"
  "$TMP/aws/install" --bin-dir "$BIN_DIR" --install-dir /usr/local/aws-cli --update >/dev/null
fi

terraform version | head -1
aws --version
