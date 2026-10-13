# OpenBao on AWS: what the POC proved (read before writing code)

Hard facts from a working 3-node OpenBao cluster on ECS Fargate + Aurora
PostgreSQL + AWS KMS auto-unseal, built and tested in October 2026. Each item
cost real debugging time. Treat them as requirements unless you have evidence
they no longer apply (check the OpenBao release notes for newer versions).

## Versions and images

1. **OpenBao 2.7.x no longer ships the `awskms` seal built in.** It is an
   external KMS plugin. Without it, 2.7.1 crash-loops with
   `Error configuring seal "awskms": unknown wrapper: awskms`.
   The plugin is declared in the server config and its name must match the
   seal name:

   ```hcl
   plugin_directory     = "/tmp/plugins"
   plugin_auto_download = true
   plugin "kms" "awskms" {
     image = "ghcr.io/openbao/openbao-plugin-kms-aws:v0.1.0@sha256:fe9fb94872048c9474156c044ea8852bb5c2e968fc9304a3725e4d434b488541"
   }
   seal "awskms" {
     region     = "<region>"
     kms_key_id = "<key id or full ARN; full ARN for a cross-account key>"
   }
   ```

   The POC downloaded the plugin from ghcr.io at every task start (needs
   internet egress). **In private subnets without internet access this fails.**
   For DEV, bake the plugin binary into a custom image in ECR instead, and use
   the `command` form of the plugin block (see `docs/DEV-TARGET.md`). The
   plugin image is multi-arch (linux/amd64 and linux/arm64 included); its
   binary sits at the image root as `/openbao-plugin-kms-aws` (mode 0644, so
   `chmod +x` it when copying it into a custom image).
2. OpenBao 2.6.x still has `awskms` built in (it logs a deprecation warning).
   Pinning 2.6.4 is the fallback if the plugin path is blocked.
3. `disable_mlock` is not supported in OpenBao 2.x (logs
   `unknown or unsupported field disable_mlock`). Leave it out.
4. Upgrading 2.6.4 → 2.7.1 as an ECS rolling deploy (one task at a time) had no
   downtime and kept all data. Snapshot the database before upgrades.

## Storage, HA and read-enabled standbys

5. With the PostgreSQL backend and `ha_enabled = "true"`, HA is a lock row in
   PostgreSQL. **No quorum**: nodes hold no data, one node can serve alone.
   OpenBao creates its own tables (`openbao_kv_store`, `openbao_ha_locks`).
6. **OpenBao 2.7 standbys are read-enabled**: they answer reads from their own
   cache and forward writes (logins, token creation, lease renewal, KV writes,
   dynamic secrets) to the active node over the cluster port 8201 (gRPC,
   mutual TLS, handled by OpenBao itself). To keep caches correct they read the
   database's WAL position. **On Aurora this requires
   `rds.logical_replication = 1`** in a custom DB *cluster* parameter group
   (static parameter, needs a writer reboot). Without it, standbys log
   `getting WAL LSN failed: ERROR: wal_level must be set to 'logical'` about
   6 times a second and the active node logs
   `failed to propagate write to peer` with a new peer ID each time.
   Alternative: `disable_standby_reads` in the storage stanza (2.6 behaviour,
   standbys forward everything).
7. **With logical replication on, Aurora Serverless v2 never auto-pauses**
   (AWS-documented; observed 0.5 ACU after 20 idle minutes). For DEV, either
   keep a non-zero minimum capacity (it is always on) or stop/start the cluster
   on a schedule. AWS restarts a stopped cluster after 7 days.
8. Aurora resume from auto-pause took **~80 s** after 2 days paused (AWS says
   ~15 s typical, 30 s+ after 24 h). A 60 s ECS health-check grace period was
   too short: a task was replaced. Use 180 s, or don't pause.
9. Database TLS: `sslmode=verify-full&sslrootcert=<regional RDS CA bundle>`
   works. `max_connect_retries = 0` makes OpenBao retry forever while the
   database starts.
10. Read-after-write through the load balancer was consistent in tests (6/6
    write-then-read rounds spread over all nodes).

## Ingress and health checks

11. Health check path:
    `/v1/sys/health?standbyok=true&uninitcode=200`. `standbyok=true` makes
    standbys answer 200, so all nodes receive traffic. That is what makes
    failover fast (seconds): standbys keep serving and only need the new
    leader's address. Routing only to the active node would make failover
    depend on health-check detection (~20–50 s). `uninitcode=200` keeps
    not-yet-initialized nodes from being killed before `init`.
12. Each task builds its config at start from its own IP (ECS task metadata
    endpoint v4): `api_addr = "http(s)://<ip>:8200"`,
    `cluster_addr = "https://<ip>:8201"`. Fargate IPs change on every
    replacement, so this cannot be static. See
    `reference/poc-terraform/files/bao-entrypoint.sh`.
13. Behind an ALB, trust `X-Forwarded-For` only from the LB subnets
    (`x_forwarded_for_authorized_addrs`). With an NLB in TLS passthrough, use
    Proxy Protocol v2 (`proxy_protocol_behavior`,
    `proxy_protocol_authorized_addrs`) to get the real client IP.

## Failover and operations

14. Failover (stop the active ECS task) with reads twice a second through the
    LB: 2.6.4 → 0 failed of 91; 2.7.1 → 1 failed of 94. During the election
    `/v1/sys/leader` briefly returns no leader (`leader_address` empty/null):
    clients and scripts must retry.
15. ECS can stop **any** task when it scales back after replacing an unhealthy
    one, including the active node. That causes a (harmless) failover.
16. A database writer reboot (~1 min) made the active node step down; a node
    retook the lock by itself when the database returned. Clients must retry.
17. **Read the logs after every change, not just health checks.** The 2.7
    standby problem left every health check green while logging ~6 errors/s.
18. Initialization with auto-unseal produces **recovery keys** (POC: 3 shares,
    threshold 2) and a root token, not unseal keys. The POC stored them in SSM
    Parameter Store (SecureString); acceptable only for a POC. Never print them.
19. Terraform S3 backend with native locking (`use_lockfile = true`): an
    interrupted apply leaves a stale lock; release it with
    `terraform force-unlock <id>` only after confirming no Terraform runs.
20. Script pitfalls fixed in the POC failover test: under `set -e`, a failed
    `curl` inside a probe loop kills the loop (append `|| true`); treat an
    empty/`null` leader as "election in progress", not as the new leader.

## Cost (eu-west-1 list prices, POC sizes)

21. POC up: ~$0.15–0.20/h (3 × 0.25 vCPU Fargate ARM, ALB, Aurora 0.5–1 ACU,
    public IPv4). Down: ~$1–1.5/month (KMS key, storage). DEV with more
    resources, always-on Aurora and VPC endpoints will be roughly
    $150–400/month depending on sizes and whether endpoints already exist.
