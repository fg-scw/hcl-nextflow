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

# ── PersistentVolumes NFS (serveur NFS sur instance Scaleway) ─────────────────
#
# Le serveur NFS est une instance BASIC3-X2C-4G avec un volume b_ssd (VirtioFS).
# data.scaleway_ipam_ip.nfs_server.address donne l'IP sur le Private Network.
# Les nœuds Kapsule dans le même PN atteignent cette IP directement.

resource "kubernetes_persistent_volume" "workdir" {
  metadata {
    name = "nf-workdir-pv"
    labels = {
      "volume-type" = "nf-workdir"
    }
  }
  spec {
    capacity = {
      storage = "${var.workdir_size_gb}Gi"
    }
    access_modes                     = ["ReadWriteMany"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = ""
    persistent_volume_source {
      nfs {
        server    = data.scaleway_ipam_ip.nfs_server.address
        path      = "/data/workdir"
        read_only = false
      }
    }
  }
  depends_on = [scaleway_instance_server.nfs_server, scaleway_instance_private_nic.nfs_server]
}

resource "kubernetes_persistent_volume_claim" "workdir" {
  metadata {
    name      = "nf-workdir-pvc"
    namespace = kubernetes_namespace.bioinformatics.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = ""
    volume_name        = kubernetes_persistent_volume.workdir.metadata[0].name
    resources {
      requests = {
        storage = "${var.workdir_size_gb}Gi"
      }
    }
  }
}

resource "kubernetes_persistent_volume" "reference" {
  metadata {
    name = "nf-reference-pv"
    labels = {
      "volume-type" = "nf-reference"
    }
  }
  spec {
    capacity = {
      storage = "${var.reference_size_gb}Gi"
    }
    access_modes                     = ["ReadWriteMany"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = ""
    persistent_volume_source {
      nfs {
        server    = data.scaleway_ipam_ip.nfs_server.address
        path      = "/data/reference"
        read_only = false
      }
    }
  }
  depends_on = [scaleway_instance_server.nfs_server, scaleway_instance_private_nic.nfs_server]
}

resource "kubernetes_persistent_volume_claim" "reference" {
  metadata {
    name      = "nf-reference-pvc"
    namespace = kubernetes_namespace.bioinformatics.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = ""
    volume_name        = kubernetes_persistent_volume.reference.metadata[0].name
    resources {
      requests = {
        storage = "${var.reference_size_gb}Gi"
      }
    }
  }
}

# ── StorageClass — scratch haute IOPS par job STAR (SBS dynamique) ─────────────
#
# VirtioFS SBS Scaleway : 2 TB → 25 687 IOPS / 201,5 MB/s (limite produit).
# Usage : PVC RWO créé à la demande pour les SAM/BAM temporaires de chaque job.
# Nextflow k8s supporte la création de PVC via la clé 'volumeClaim' dans pod{}.
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
    data.scaleway_ipam_ip.nfs_server,
  ]
}
