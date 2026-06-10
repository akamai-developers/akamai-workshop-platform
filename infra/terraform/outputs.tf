output "kubeconfig" {
  description = "Kubeconfig for the LKE cluster (base64 encoded)"
  value       = linode_lke_cluster.workshop.kubeconfig
  sensitive   = true
}

output "cluster_id" {
  description = "LKE cluster ID"
  value       = linode_lke_cluster.workshop.id
}

output "api_endpoints" {
  description = "Kubernetes API endpoints"
  value       = linode_lke_cluster.workshop.api_endpoints
}

output "cluster_status" {
  description = "Cluster status"
  value       = linode_lke_cluster.workshop.status
}

output "ingress_firewall_id" {
  description = "Linode Cloud Firewall ID. Attached automatically to the ingress LB via Helm values."
  value       = linode_firewall.ingress.id
}

output "ingress_lb_ip" {
  description = "Public IP of the ingress NodeBalancer. DNS records below resolve to this."
  value       = local.lb_ip
}

output "base_host" {
  description = "Base host for student URLs: https://s01.<this>, s02.<this>, … In no-domain mode this is <lb-ip-dashed>.sslip.io; with a domain it is <prefix>.<domain>."
  value       = local.base_host
}

output "gpu_pool_labels" {
  description = "Labels assigned to GPU node pools. Single-model: [\"gpu\"]. Multi-model: per-model labels."
  value       = keys(local.effective_gpu_pools)
}
