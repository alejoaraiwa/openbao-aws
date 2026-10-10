# Runs inside the OpenBao container (alpine, /bin/sh). Builds the server config
# from the task's own IP, then execs the server.
set -eu

# This task's private IP (awsvpc ENI), from the ECS container metadata endpoint.
IP="$(wget -qO- "$ECS_CONTAINER_METADATA_URI_V4" | tr -d ' \n' | sed -n 's/.*"IPv4Addresses":\["\([0-9.]*\)".*/\1/p')"
if [ -z "$IP" ]; then
  echo "could not determine task IP from ECS metadata" >&2
  exit 1
fi

echo "$RDS_CA_B64" | base64 -d > /tmp/rds-ca.pem
mkdir -p /tmp/plugins

cat > /tmp/bao.hcl <<HCL
ui            = true
cluster_name  = "openbao-poc"
api_addr      = "http://${IP}:8200"
cluster_addr  = "https://${IP}:8201"

# From 2.7 the AWS KMS seal is an external plugin, downloaded (OCI image pinned
# by digest) into the task's ephemeral disk at every start.
plugin_directory     = "/tmp/plugins"
plugin_auto_download = true

plugin "kms" "awskms" {
  image = "${KMS_PLUGIN_IMAGE}"
}

# TLS terminates at the load balancer; node-to-node traffic on 8201 is always
# mutually-authenticated TLS regardless of this setting.
listener "tcp" {
  address                             = "0.0.0.0:8200"
  cluster_address                     = "0.0.0.0:8201"
  tls_disable                         = true
  x_forwarded_for_authorized_addrs    = "${VPC_CIDR}"
  x_forwarded_for_reject_not_present  = false
}

# Password comes from PGPASSWORD (injected from Secrets Manager).
storage "postgresql" {
  connection_url      = "postgres://${PG_USER}@${PG_HOST}:5432/${PG_DB}?sslmode=verify-full&sslrootcert=/tmp/rds-ca.pem"
  ha_enabled          = "true"
  max_connect_retries = 0
}

# Name must match the plugin "kms" block above.
seal "awskms" {
  region     = "${AWS_REGION}"
  kms_key_id = "${KMS_KEY_ID}"
}
HCL

echo "starting openbao on ${IP}"
exec bao server -config=/tmp/bao.hcl
