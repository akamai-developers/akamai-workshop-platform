terraform {
  required_version = ">= 1.5"
}

provider "linode" {
  token = var.token
}

locals {
  kubeconfig = yamldecode(base64decode(linode_lke_cluster.workshop.kubeconfig))
}

provider "helm" {
  kubernetes {
    host                   = local.kubeconfig.clusters[0].cluster.server
    cluster_ca_certificate = base64decode(local.kubeconfig.clusters[0].cluster["certificate-authority-data"])
    token                  = local.kubeconfig.users[0].user.token
  }
}

provider "kubernetes" {
  host                   = local.kubeconfig.clusters[0].cluster.server
  cluster_ca_certificate = base64decode(local.kubeconfig.clusters[0].cluster["certificate-authority-data"])
  token                  = local.kubeconfig.users[0].user.token
}

resource "linode_lke_cluster" "workshop" {
  label       = var.label
  k8s_version = var.k8s_version
  region      = var.region
  tags        = ["akamai-workshop-platform"]

  pool {
    type  = var.cpu_node_type
    count = var.cpu_node_count
  }
}

resource "linode_lke_node_pool" "gpu" {
  cluster_id = linode_lke_cluster.workshop.id
  type       = var.gpu_node_type
  node_count = var.gpu_node_count

  labels = {
    pool = "gpu"
  }
}

resource "linode_firewall" "ingress" {
  label           = "${var.label}-ingress"
  inbound_policy  = "DROP"
  outbound_policy = "ACCEPT"

  inbound {
    label    = "allow-http"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "80"
    ipv4     = [var.allowed_cidr]
  }

  inbound {
    label    = "allow-https"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "443"
    ipv4     = [var.allowed_cidr]
  }
}

resource "helm_release" "cloud_firewall_crd" {
  name             = "cloud-firewall-crd"
  repository       = "https://linode.github.io/cloud-firewall-controller"
  chart            = "cloud-firewall-crd"
  namespace        = "kube-system"
  create_namespace = false
  wait             = true
  timeout          = 300

  depends_on = [linode_lke_cluster.workshop, linode_lke_node_pool.gpu]
}

resource "helm_release" "cloud_firewall_controller" {
  name             = "cloud-firewall"
  repository       = "https://linode.github.io/cloud-firewall-controller"
  chart            = "cloud-firewall-controller"
  namespace        = "kube-system"
  create_namespace = false
  wait             = true
  timeout          = 300

  depends_on = [helm_release.cloud_firewall_crd]
}

resource "helm_release" "gpu_operator" {
  name             = "gpu-operator"
  repository       = "https://helm.ngc.nvidia.com/nvidia"
  chart            = "gpu-operator"
  namespace        = "gpu-operator"
  create_namespace = true
  wait             = true
  timeout          = 900

  depends_on = [linode_lke_node_pool.gpu]
}

resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true
  wait             = true
  timeout          = 600
  force_update     = true

  # NOTE: not attaching linode_firewall.ingress to the LB via annotation —
  # Linode CCM has rejected valid firewall IDs in testing. The firewall
  # resource is retained for manual attachment via the Cloud Manager if needed.
  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/linode-loadbalancer-throttle"
    value = "0"
  }

  depends_on = [linode_lke_cluster.workshop]
}

# Domain mode only. In no-domain mode (var.domain == "") this data source and the
# DNS records below are skipped entirely (count = 0); hostnames come from sslip.io.
data "linode_domain" "workshop" {
  count  = var.domain == "" ? 0 : 1
  domain = var.domain
}

data "kubernetes_service" "ingress_lb" {
  metadata {
    name      = "ingress-nginx-controller"
    namespace = "ingress-nginx"
  }

  depends_on = [helm_release.ingress_nginx]
}

locals {
  lb_ip        = data.kubernetes_service.ingress_lb.status[0].load_balancer[0].ingress[0].ip
  lb_ip_dashed = replace(local.lb_ip, ".", "-")
  # No domain → sslip.io: sNN.<lb-ip-dashed>.sslip.io resolves to the LB IP with no DNS.
  # Domain → <prefix>.<domain> served by the Linode DNS records below.
  base_host = var.domain == "" ? "${local.lb_ip_dashed}.sslip.io" : "${var.subdomain_prefix}.${var.domain}"
}

resource "linode_domain_record" "workshop_wildcard" {
  count       = var.domain == "" ? 0 : 1
  domain_id   = data.linode_domain.workshop[0].id
  name        = "*.${var.subdomain_prefix}"
  record_type = "A"
  target      = local.lb_ip
  ttl_sec     = 300
}

resource "linode_domain_record" "workshop_apex" {
  count       = var.domain == "" ? 0 : 1
  domain_id   = data.linode_domain.workshop[0].id
  name        = var.subdomain_prefix
  record_type = "A"
  target      = local.lb_ip
  ttl_sec     = 300
}
