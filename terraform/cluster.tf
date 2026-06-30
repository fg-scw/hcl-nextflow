# ── VPC ───────────────────────────────────────────────────────────────────────
resource "scaleway_vpc" "main" {
  name       = "${var.cluster_name}-vpc"
  region     = var.scaleway_region
  project_id = var.scw_project_id
  tags       = var.tags
}

# ── Private Network ───────────────────────────────────────────────────────────
resource "scaleway_vpc_private_network" "main" {
  name       = "${var.cluster_name}-pn"
  vpc_id     = scaleway_vpc.main.id
  region     = var.scaleway_region
  project_id = var.scw_project_id
  tags       = var.tags

  ipv4_subnet {
    subnet = var.vpc_cidr
  }
}

# ── Kapsule Cluster (Cilium CNI) ──────────────────────────────────────────────
resource "scaleway_k8s_cluster" "main" {
  name       = "${var.cluster_name}-kapsule"
  version    = var.k8s_version
  cni        = "cilium"
  region     = var.scaleway_region
  project_id = var.scw_project_id

  # L'API Kapsule stocke l'UUID nu, contrairement à l'ID régional du resource VPC.
  # Passer l'ID régional provoquerait un faux diff et remplacerait le cluster.
  private_network_id = split("/", scaleway_vpc_private_network.main.id)[1]

  # Le VPC et le Private Network sont gérés par Terraform. Si cette option est
  # activée, Kapsule supprime aussi le PN lors d'un remplacement du cluster,
  # laissant son ID orphelin dans le state avant la recréation du cluster.
  delete_additional_resources = false

  # scw-filestorage-csi active le driver CSI File Storage (SFS) préinstallé
  # sur Kapsule — requis pour les PVCs ReadWriteMany via sfs-standard.
  tags = concat(var.tags, ["scw-filestorage-csi"])

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
    log_level                       = 2
    skip_nodes_with_local_storage   = false
  }
}
