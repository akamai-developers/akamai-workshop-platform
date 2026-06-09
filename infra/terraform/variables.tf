variable "token" {
  description = "Linode API token"
  type        = string
  sensitive   = true
}

variable "region" {
  description = "Linode region"
  type        = string
  default     = "us-ord"
}

variable "k8s_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.34"
}

variable "label" {
  description = "Cluster label"
  type        = string
  default     = "ai-agents-workshop"
}

variable "cpu_node_type" {
  description = "Linode instance type for CPU pool (workspaces)"
  type        = string
  default     = "g6-dedicated-8"
}

variable "cpu_node_count" {
  description = "Number of CPU nodes for workspaces. Default sized for 80 students."
  type        = number
  default     = 5
}

variable "gpu_node_type" {
  description = "Linode instance type for GPU pool (vLLM). Default is 4-GPU-per-node; vLLM runs with --tensor-parallel-size=4 to pool VRAM into one big KV cache per replica."
  type        = string
  default     = "g2-gpu-rtx4000a4-s"
}

variable "gpu_node_count" {
  description = "Number of GPU nodes for vLLM. Each runs one vLLM replica (which itself spans all GPUs on the node via tensor parallelism)."
  type        = number
  default     = 5
}

variable "multi_model" {
  description = "Enable multi-model mode with per-model GPU pools and agentgateway routing."
  type        = bool
  default     = false
}

variable "gpu_pools" {
  description = "Per-model GPU pool definitions (multi-model mode only). Each entry creates a separate node pool with a distinct label for nodeSelector-based scheduling."
  type = list(object({
    type  = string
    count = number
    label = string
  }))
  default = []
}

variable "allowed_cidr" {
  description = "CIDR allowed to reach the workshop ingress on 80/443. Default is open; set to a CIDR (e.g. classroom IP) to restrict."
  type        = string
  default     = "0.0.0.0/0"
}

variable "domain" {
  description = "Apex domain managed in Linode DNS. Empty (\"\") means no-domain mode: sslip.io hostnames + self-signed TLS. Set it to opt into Linode DNS + Let's Encrypt."
  type        = string
  default     = ""
}

variable "subdomain_prefix" {
  description = "Subdomain under the apex for the workshop. Students get s01.<prefix>.<domain>, s02.<prefix>.<domain>, etc."
  type        = string
  default     = "workshop"
}

variable "cert_email" {
  description = "Email used for Let's Encrypt registration and renewal notices (domain mode only)."
  type        = string
  default     = ""
}
