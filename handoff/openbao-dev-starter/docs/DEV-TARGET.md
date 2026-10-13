# DEV target: proposed design (to confirm with the team)

Starting point for the DEV deployment in the company AWS account. Everything
marked **[ASK]** must be confirmed before writing Terraform; company standards
win over this document.

## Coexistence with what already runs in the account

The DEV account already holds the **KMS key that unseals the on-prem OpenShift
OpenBao DEV cluster** and **S3 bucket(s) with OpenBao snapshots**. This project:

- creates its **own** KMS key for the ECS cluster's unseal. Sharing the on-prem
  key would tie two clusters' fate to one key policy and make a mistake in this
  project able to break on-prem unseal;
- does not use the snapshot bucket (Aurora backups need no S3 bucket);
- scopes every IAM policy to its own ARNs, prefixes every name, tags
  everything, never imports existing resources, and gates every apply with
  `scripts/plan-guard.sh` (refuses updates/deletes unless approved by name).

**Nothing is public.** Internal NLB only, private subnets, no public IPs,
ingress only from agreed corporate CIDRs, Block Public Access on any bucket, no
`"Principal": "*"` policies. Any exception needs an explicit request, a warning
and a confirmation; `scripts/plan-guard.sh` refuses public exposure otherwise.

`scripts/discover.sh` lists the existing resources first; the agreed plan
(`docs/DEV-PLAN.md`) names them in a "will never be touched" section.

## Shape

```
on-prem / VPN / other VPCs
        │  TCP 443 (TLS end to end)
        ▼
internal NLB (private subnets, 3 AZs) ── TCP passthrough, optional Proxy Protocol v2
        │  TCP 8200
        ▼
ECS Fargate service: 3 OpenBao tasks (1 per AZ), private subnets, no public IPs
   TLS listener on 8200 (node certificate), cluster port 8201 (OpenBao mTLS)
        │                         │                     │
        ▼                         ▼                     ▼
Aurora PostgreSQL 16        KMS key (unseal)      ECR (custom image with
(TLS verify-full)                                  the KMS plugin baked in)
```

## Decisions (defaults, override with company standards)

| Area | DEV default | Notes |
|---|---|---|
| Network | Existing company VPC, private subnets in 3 AZs **[ASK]** | No public IPs. Egress via existing NAT/egress or VPC endpoints **[ASK]** |
| VPC endpoints (if no egress) | ecr.api, ecr.dkr, s3 (gateway), logs, kms, sts, ssm, ssmmessages, secretsmanager | Skip any that the network team already provides centrally |
| Ingress | **Internal NLB**, TCP listener 443 → target group TCP 8200 (IP targets) | TLS terminates on OpenBao = end to end. Client certificates (`cert` auth) possible |
| Client IP | Proxy Protocol v2 on the target group + `proxy_protocol_behavior = "allow_authorized"`, `proxy_protocol_authorized_addrs` = NLB subnets | Verify NLB health checks still pass with Proxy Protocol on |
| Health check | HTTPS on 8200, path `/v1/sys/health?standbyok=true&uninitcode=200`, matcher 200 | NLB does not validate the target certificate |
| DNS | Name such as `openbao.dev.<company domain>` → NLB **[ASK]** | Route 53 private hosted zone or corporate DNS |
| Node TLS cert | SAN = the DEV DNS name (+ NLB DNS name). Source **[ASK]**: (a) company internal PKI; (b) AWS Private CA (has a monthly cost); (c) Terraform `tls` provider with a DEV-only CA | Store cert + key in Secrets Manager; inject as ECS secrets; entrypoint writes them to files |
| Node sizing | 3 tasks × 1 vCPU / 2 GB, ARM64 | POC used 0.25 / 0.5 GB. Adjust after a load test |
| ECS | Rolling deploy min 66% / max 134%, health-check grace 180 s, ECS Exec on | See LEARNINGS 8, 15 |
| Image | Custom image in ECR: OpenBao 2.7.x + KMS plugin binary, pinned by digest | No runtime download from ghcr.io (see below) |
| Database | Aurora PostgreSQL 16 Serverless v2, min 0.5 / max 4 ACU, writer (+ optional reader in another AZ), **custom cluster parameter group with `rds.logical_replication = 1`**, 7-day backups, encrypted with a CMK, deletion protection **[ASK]** | No auto-pause (logical replication prevents it anyway) |
| Seal | **New** KMS CMK for this cluster in the DEV account (or a security account **[ASK]**), key policy limited to the task role (Encrypt, Decrypt, DescribeKey). Never the on-prem unseal key | Use the full key ARN if cross-account |
| Secrets | DB password: Secrets Manager or SSM SecureString **[ASK]**. Init output: recovery keys PGP-encrypted to named people if possible, otherwise SSM SecureString with a restricted KMS key | Never print root token or recovery keys |
| Audit | Enable a `file` audit device writing to `stdout` (goes to CloudWatch) right after init | Ship to the SIEM if required **[ASK]** |
| IaC | Terraform, remote state per company standard **[ASK]** (a new state bucket/key, never the snapshot bucket), name prefix and tags per company standard **[ASK]** | Every apply through `scripts/plan-guard.sh`; everything via CLI/Terraform, no console |

## Custom image (plugin baked in)

```dockerfile
# Pin both by digest in practice.
FROM ghcr.io/openbao/openbao-plugin-kms-aws:v0.1.0@sha256:fe9fb94872048c9474156c044ea8852bb5c2e968fc9304a3725e4d434b488541 AS plugin
FROM quay.io/openbao/openbao:2.7.1
# The binary is stored with mode 0644 in the plugin image: make it executable.
COPY --from=plugin --chmod=0755 /openbao-plugin-kms-aws /openbao/plugins/openbao-plugin-kms-aws
```

Build for `linux/arm64` (Fargate ARM64), push to ECR, and reference by digest.
Server config:

```hcl
plugin_directory = "/openbao/plugins"
plugin "kms" "awskms" {
  command = "openbao-plugin-kms-aws"
  version = "v0.1.0"
  # Recommended: pins the exact binary. v0.1.0 linux/arm64 binary (verified 2026-10-13):
  sha256sum = "9925bd77bb644fbf8a3a479deb39768e5a230e9b2b4eafad18971b54b3b580e2"
}
seal "awskms" { region = "..." kms_key_id = "..." }
```

Verified (2026-10-13): in the plugin image the binary is
`/openbao-plugin-kms-aws` at the root (it is the image entrypoint), linux/arm64
sha256 `9925bd77…b580e2`, file mode 0644 (hence `--chmod=0755`).
Not verified in the POC (it used the OCI `image` form): the `command` form
itself and whether `version` must match what the plugin reports. Check with a
local `docker run` before deploying.

## TLS listener (node side)

```hcl
listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_cert_file   = "/tmp/tls/bao.crt"   # written by the entrypoint from ECS secrets
  tls_key_file    = "/tmp/tls/bao.key"
  tls_min_version = "tls12"
  # Proxy Protocol from the NLB (if enabled on the target group):
  # proxy_protocol_behavior         = "allow_authorized"
  # proxy_protocol_authorized_addrs = "<NLB subnet CIDRs>"
}
api_addr     = "https://<task ip>:8200"
cluster_addr = "https://<task ip>:8201"
```

Clients connect to `https://openbao.dev.<company domain>` and must trust the
issuing CA (`VAULT_CACERT` / `BAO_CACERT`).

## Tests to run before calling DEV done

1. `openssl s_client -connect <dev name>:443 -servername <dev name>` shows the
   node certificate, issued by the expected CA, and TLS 1.2+.
2. All 3 targets healthy; `/v1/sys/ha-status` lists 3 nodes, 1 active.
3. Logs: standbys say `entering read-enabled standby mode`; zero
   `wal_level` errors; no repeating `[ERROR]` lines for 10 minutes.
4. Failover test (adapt `reference/poc-scripts/failover-test.sh`): failed
   requests ≤ 1–2, new leader within seconds.
5. Database writer reboot: cluster recovers by itself.
6. Audit log entries visible in CloudWatch with the real client IP.
7. Restore test: Aurora point-in-time restore to a new cluster, point a test
   deployment at it, unseal, read a known secret.
