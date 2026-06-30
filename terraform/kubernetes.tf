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

# ── NFS Server in-cluster ─────────────────────────────────────────────────────
#
# scaleway_block_volume_attachment n'existe pas dans le provider 2.76.
# On déploie nfs-server comme pod K8s avec un PVC scw-bssd (RWO, SBS natif
# Kapsule). Le PVC est provisionné dynamiquement par le CSI driver bs.csi.scaleway.com.
#
# Accès depuis kubelet : Cilium sur Kapsule utilise des hooks eBPF cgroup-level
# qui interceptent les connexions ClusterIP depuis le namespace hôte (kubelet).
# Les mounts NFS depuis le kubelet via ClusterIP sont donc supportés.
#
# Performance : scw-bssd VirtioFS, 2 500 GB → ~32 000 IOPS / ~250 MB/s.

resource "kubernetes_persistent_volume_claim" "nfs_backing" {
  metadata {
    name      = "nfs-server-data"
    namespace = kubernetes_namespace.bioinformatics.metadata[0].name
    annotations = {
      "description" = "Backing storage SBS pour le serveur NFS in-cluster — workdir + reference"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "scw-bssd"
    resources {
      requests = {
        storage = "${var.workdir_size_gb + var.reference_size_gb}Gi"
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_deployment" "nfs_server" {
  metadata {
    name      = "nfs-server"
    namespace = kubernetes_namespace.bioinformatics.metadata[0].name
    labels    = { app = "nfs-server" }
  }
  spec {
    replicas = 1
    selector {
      match_labels = { app = "nfs-server" }
    }
    # Recreate pour éviter deux pods en simultané sur le même PVC RWO
    strategy {
      type = "Recreate"
    }
    template {
      metadata {
        labels = { app = "nfs-server" }
      }
      spec {
        # Pinné sur le pool orchestrator (toujours actif, min_size=1)
        node_selector = {
          "k8s.scaleway.com/pool-name" = "orchestrator"
        }

        # Crée les sous-répertoires avant que nfs-server démarre
        init_container {
          name              = "init-dirs"
          image             = "busybox:1.36"
          image_pull_policy = "IfNotPresent"
          command           = ["sh", "-c", "mkdir -p /data/workdir /data/reference && chmod 777 /data/workdir /data/reference"]
          volume_mount {
            name       = "nfs-data"
            mount_path = "/data"
          }
        }

        container {
          name              = "nfs"
          image             = "erichough/nfs-server:2.2.1"
          image_pull_policy = "IfNotPresent"

          # Exports NFSv4 : /data est la racine (fsid=0), /data/workdir et
          # /data/reference exposés comme chemins absolus pour NFSv3 et NFSv4.
          env {
            name  = "NFS_EXPORT_0"
            value = "/data *(rw,fsid=0,no_subtree_check,no_auth_nlm,insecure,no_root_squash)"
          }
          env {
            name  = "NFS_EXPORT_1"
            value = "/data/workdir *(rw,nohide,no_subtree_check,no_auth_nlm,insecure,no_root_squash)"
          }
          env {
            name  = "NFS_EXPORT_2"
            value = "/data/reference *(rw,nohide,no_subtree_check,no_auth_nlm,insecure,no_root_squash)"
          }

          # Requis pour charger les modules NFS du kernel hôte
          security_context {
            privileged = true
            capabilities {
              add = ["SYS_ADMIN", "SETPCAP"]
            }
          }

          port {
            name           = "nfs"
            container_port = 2049
            protocol       = "TCP"
          }
          port {
            name           = "nfs-portmap"
            container_port = 111
            protocol       = "UDP"
          }

          volume_mount {
            name       = "nfs-data"
            mount_path = "/data"
          }
        }

        volume {
          name = "nfs-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.nfs_backing.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [kubernetes_persistent_volume_claim.nfs_backing]

  timeouts {
    create = "10m"
  }
}

# Service ClusterIP stable — kubelet monte l'IP ClusterIP via Cilium eBPF
resource "kubernetes_service" "nfs_server" {
  metadata {
    name      = "nfs-server"
    namespace = kubernetes_namespace.bioinformatics.metadata[0].name
  }
  spec {
    selector = { app = "nfs-server" }
    port {
      name        = "nfs"
      port        = 2049
      target_port = 2049
      protocol    = "TCP"
    }
    port {
      name        = "nfs-portmap"
      port        = 111
      target_port = 111
      protocol    = "UDP"
    }
  }
  depends_on = [kubernetes_deployment.nfs_server]
}

# ── PersistentVolumes NFS (serveur NFS in-cluster) ────────────────────────────
#
# nfs.server = ClusterIP du service nfs-server (résolu après création du Service).
# Les mount options NFSv4 évitent rpcbind et améliorent le débit bioinformatique.

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
    mount_options                    = ["nfsvers=4", "rsize=1048576", "wsize=1048576", "hard", "intr"]
    persistent_volume_source {
      nfs {
        server    = kubernetes_service.nfs_server.spec[0].cluster_ip
        path      = "/data/workdir"
        read_only = false
      }
    }
  }
  depends_on = [kubernetes_service.nfs_server]
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
    mount_options                    = ["nfsvers=4", "rsize=1048576", "wsize=1048576", "hard", "intr"]
    persistent_volume_source {
      nfs {
        server    = kubernetes_service.nfs_server.spec[0].cluster_ip
        path      = "/data/reference"
        read_only = false
      }
    }
  }
  depends_on = [kubernetes_service.nfs_server]
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
  ]
}
