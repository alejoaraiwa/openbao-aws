variable "name" {
  description = "Prefix for all resource names."
  type        = string
  default     = "openbao-poc"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "eu-west-1"
}

variable "zone_name" {
  description = "Cloudflare zone that hosts the public hostname."
  type        = string
  default     = "ubts.es"
}

variable "hostname" {
  description = "Subdomain (within zone_name) OpenBao is published at."
  type        = string
  default     = "bao"
}

variable "openbao_image" {
  description = "OpenBao container image."
  type        = string
  default     = "quay.io/openbao/openbao:2.7.1"
}

# From 2.7.0 the awskms seal is not built in; without this plugin the server
# fails with "unknown wrapper: awskms".
variable "kms_plugin_image" {
  description = "OCI image of the AWS KMS seal plugin, pinned by digest."
  type        = string
  default     = "ghcr.io/openbao/openbao-plugin-kms-aws:v0.1.0@sha256:fe9fb94872048c9474156c044ea8852bb5c2e968fc9304a3725e4d434b488541"
}

variable "node_count" {
  description = "Number of OpenBao tasks (one active, the rest standby)."
  type        = number
  default     = 3
}

variable "running" {
  description = "true = cluster up (tasks, load balancer, DNS). false = only free/near-free resources remain and the database pauses."
  type        = bool
  default     = false
}

variable "task_cpu" {
  description = "Fargate CPU units per task (256 = 0.25 vCPU, the minimum)."
  type        = number
  default     = 256
}

variable "task_memory" {
  type    = number
  default = 512
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to reach the load balancer."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "budget_limit_usd" {
  description = "Monthly budget; alerts at 50%/80% actual and 100% forecast."
  type        = number
  default     = 10
}

variable "alert_email" {
  description = "Email address for budget alerts; empty = no budget."
  type        = string
  default     = ""
}
