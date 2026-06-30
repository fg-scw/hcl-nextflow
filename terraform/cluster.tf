# ── VPC ───────────────────────────────────────────────────────────────────────
resource "scaleway_vpc" "main" {
  name   = "${var.cluster_name}-vpc"
  region = var.scaleway_region
  tags   = var.tags
}

# ── Private Network ───────────────────────────────────────────────────────────
resource "scaleway_vpc_private_network" "main" {
  name   = "${var.cluster_name}-pn"
  vpc_id = scaleway_vpc.main.id
  region = var.scaleway_region
  tags   = var.tags

  ipv4_subnet {
    subnet = var.vpc_cidr
  }
}

# ── Kapsule Cluster (Cilium CNI) ──────────────────────────────────────────────
resource "scaleway_k8s_cluster" "main" {
  name               = "${var.cluster_name}-kapsule"
  version            = var.k8s_version
  cni                = "cilium"
  region             = var.scaleway_region
  private_network_id = scaleway_vpc_private_network.main.id

  # Nettoie les LBs, IPs et volumes créés par le cluster lors du destroy.
  delete_additional_resources = true

  tags = var.tags

  auto_upgrade {
    enable                        = false
    maintenance_window_start_hour = 3
    maintenance_window_day        = "sunday"
  }

  # Cluster Autoscaler — aggressif sur le scale-down pour limiter les coûts.
  # Scaleway Kapsule n'a pas de Spot instances : le scale-to-zero du pool
  # compute est la principale source d'économie entre les runs.
  autoscaler_config {
    disable_scale_down              = false
    scale_down_delay_after_add      = "5m"
    scale_down_unneeded_time        = "10m"
    estimator                       = "binpacking"
    expander                        = "least_waste"
    ignore_daemonsets_utilization   = true
    balance_similar_node_groups     = false
    expendable_pods_priority_cutoff = -10
  }
}
