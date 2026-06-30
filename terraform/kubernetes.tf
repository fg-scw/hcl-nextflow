# ── Namespace ─────────────────────────────────────────────────────────────────
resource "kubernetes_namespace" "bioinformatics" {
  metadata {
    name = "bioinformatics"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "project"                      = "nf-rnaseq"
    }
  }
  depends_on = [scaleway_k8s_pool.orchestrator]
}

# ── RBAC — Nextflow crée et surveille les pods task ───────────────────────────
resource "kubernetes_service_account" "nextflow" {
  metadata {
    name      = "nextflow"
    namespace = kubernetes_namespace.bioinformatics.metadata[0].name
  }
}

resource "kubernetes_cluster_role" "nextflow_pod_manager" {
  metadata {
    name = "nextflow-pod-manager"
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log", "pods/status"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  rule {
    api_groups = [""]
    resources  = ["persistentvolumeclaims"]
    verbs      = ["get", "list", "watch", "create", "delete"]
  }
  rule {
    api_groups = [""]
    resources  = ["secrets", "configmaps"]
    verbs      = ["get", "list"]
  }
  rule {
    api_groups = [""]
    resources  = ["nodes"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_cluster_role_binding" "nextflow" {
  metadata {
    name = "nextflow-pod-manager"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.nextflow_pod_manager.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.nextflow.metadata[0].name
    namespace = kubernetes_namespace.bioinformatics.metadata[0].name
  }
}

# ── Stockage partagé via Scaleway File Storage CSI (sfs-standard, RWX) ────────
#
# Le driver filestorage.csi.scaleway.com est préinstallé sur Kapsule et activé
# par le tag scw-filestorage-csi au niveau du cluster (voir cluster.tf).
# Il provisionne dynamiquement des volumes SFS en ReadWriteMany — tous les pods
# task Nextflow (sur N nœuds compute) montent le même volume simultanément,
# sans serveur NFS intermédiaire.
#
# Taille minimale SFS : 25 GB. Performance : proportionnelle à la taille
# provisionnée (IOPS et débit scalent linéairement).

resource "kubernetes_persistent_volume_claim" "workdir" {
  metadata {
    name      = "nf-workdir-pvc"
    namespace = kubernetes_namespace.bioinformatics.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = "sfs-standard"
    resources {
      requests = {
        # Le driver SFS exige un multiple de 1 GB décimal ; utiliser G, pas Gi.
        storage = "${var.workdir_size_gb}G"
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_persistent_volume_claim" "reference" {
  metadata {
    name      = "nf-reference-pvc"
    namespace = kubernetes_namespace.bioinformatics.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = "sfs-standard"
    resources {
      requests = {
        # Le driver SFS exige un multiple de 1 GB décimal ; utiliser G, pas Gi.
        storage = "${var.reference_size_gb}G"
      }
    }
  }
  wait_until_bound = false
}

# ── StorageClass — scratch haute IOPS par job STAR (SBS dynamique) ─────────────
#
# VirtioFS SBS Scaleway : 2 TB → 25 687 IOPS / 201,5 MB/s (limite produit).
# Usage : PVC RWO créé à la demande pour les SAM/BAM temporaires de chaque job.
# reclaimPolicy=Delete : le volume est supprimé à la fin du job (pas de coût résiduel).
resource "kubernetes_storage_class" "star_scratch" {
  metadata {
    name = "star-scratch"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "false"
    }
  }
  storage_provisioner    = "bs.csi.scaleway.com"
  reclaim_policy         = "Delete"
  allow_volume_expansion = true
  volume_binding_mode    = "WaitForFirstConsumer"

  parameters = {
    type = "bssd"
  }
}

# ── Secret K8s — credentials S3 injectés dans les pods task ──────────────────
resource "kubernetes_secret" "pipeline_s3" {
  metadata {
    name      = "pipeline-s3-credentials"
    namespace = kubernetes_namespace.bioinformatics.metadata[0].name
  }
  type = "Opaque"

  data = {
    "access-key"     = scaleway_iam_api_key.nextflow_pipeline.access_key
    "secret-key"     = scaleway_iam_api_key.nextflow_pipeline.secret_key
    "s3-endpoint"    = "https://s3.${var.scaleway_region}.scw.cloud"
    "input-bucket"   = scaleway_object_bucket.data["input"].name
    "results-bucket" = scaleway_object_bucket.data["results"].name
  }
}

# ── ConfigMap — nextflow.config embarqué dans le cluster ─────────────────────
resource "kubernetes_config_map" "nextflow_config" {
  metadata {
    name      = "nextflow-config"
    namespace = kubernetes_namespace.bioinformatics.metadata[0].name
  }

  data = {
    "nextflow.config" = file("${path.module}/../nextflow/nextflow.config")
  }

  depends_on = [
    kubernetes_persistent_volume_claim.workdir,
    kubernetes_persistent_volume_claim.reference,
    kubernetes_storage_class.star_scratch,
    scaleway_k8s_pool.orchestrator,
  ]
}
