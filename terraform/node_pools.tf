# ── Pool orchestrateur — Nextflow head job (toujours actif) ───────────────────
#
# BASIC3-X4C-16G : 4 vCPU / 16 GB RAM
# min=1 : ce nœud ne scale jamais à 0 — le processus Nextflow doit survivre
# entre les runs sans interruption pour conserver son état (résumabilité -resume).
resource "scaleway_k8s_pool" "orchestrator" {
  cluster_id  = scaleway_k8s_cluster.main.id
  name        = "orchestrator"
  node_type   = var.orchestrator_node_type
  size        = 1
  min_size    = 1
  max_size    = var.orchestrator_max_nodes
  autoscaling = true
  autohealing = true
  region      = var.scaleway_region
  zone        = var.scaleway_zone
  tags        = concat(var.tags, ["role=orchestrator"])

  upgrade_policy {
    max_unavailable = 1
    max_surge       = 1
  }

  # Le Cluster Autoscaler gère le size — Terraform ne doit pas écraser ses décisions.
  lifecycle {
    ignore_changes = [size]
  }
}

# ── Pool compute — jobs STAR (scale-to-zero entre les runs) ───────────────────
#
# POC : MEMORY3-X8C-64G (8 vCPU / 64 GB) — 1 job STAR par nœud (7 vCPU / 52 GB).
# Alternative prod : MEMORY3-X32C-256G (4 jobs/nœud) ou POP2-HM-32C-256G.
# L'index GRCh38 (~32 GB) est chargé intégralement en RAM — 52 GB/job est le minimum
# validé (40 GB strict minimum, STAR échoue silencieusement en dessous).
#
# Note Spot : Scaleway Kapsule ne propose pas d'instances Spot/Préemptibles.
# Le scale-to-zero (min=0) est le mécanisme d'économie principal :
# le Cluster Autoscaler déprovisionne les nœuds inactifs après 10 min.
# Nextflow gère les retries natifs en cas de perte de nœud (-resume).
resource "scaleway_k8s_pool" "star_compute" {
  cluster_id  = scaleway_k8s_cluster.main.id
  name        = "star-compute"
  node_type   = var.compute_node_type
  size        = 1   # Kapsule refuse size=0 à la création — le Cluster Autoscaler ramène à 0 après 10 min d'inactivité
  min_size    = 0
  max_size    = var.compute_max_nodes
  autoscaling = true
  autohealing = true
  region      = var.scaleway_region
  zone        = var.scaleway_zone
  tags        = concat(var.tags, ["role=star-compute"])

  # Taint : seuls les pods avec la tolération explicite s'exécutent ici.
  # Nextflow injecte automatiquement la tolération via le pod spec dans nextflow.config.
  taints {
    key    = "workload"
    value  = "star-compute"
    effect = "NoSchedule"
  }

  upgrade_policy {
    max_unavailable = 1
    max_surge       = 0
  }

  # Le Cluster Autoscaler peut scaler ce pool à 0 entre les runs.
  # Sans ignore_changes, Terraform lirait size=0 depuis l'API et tenterait
  # de le remettre à 1, déclenchant une erreur Kapsule "can't have less than 1 nodes".
  lifecycle {
    ignore_changes = [size]
  }
}
