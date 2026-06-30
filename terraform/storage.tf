# ── NFS Server — stockage partagé RWX pour Nextflow ──────────────────────────
#
# scaleway_file_system (SFS) n'est pas encore disponible dans le provider
# Scaleway ≤ 2.76. On utilise une instance dédiée BASIC3-X2C-4G avec un volume
# b_ssd (Block SSD, VirtioFS) comme serveur NFS. L'instance est attachée au
# même Private Network que le cluster Kapsule.
#
# Performance b_ssd VirtioFS (même technologie que SFS) :
#   2 500 GB → ~32 000 IOPS / ~250 MB/s (proportionnel à la taille).
# Workdir + reference sur le même volume, dans deux sous-répertoires /data/workdir
# et /data/reference montés séparément via deux NFS PVs.
#
# TIMING : cloud-init prend 2-3 min après création de l'instance.
# Les PVCs Kubernetes réessaient automatiquement le bind toutes les 20 s.
# Exécuter 'kubectl get pvc -n bioinformatics -w' pour surveiller.

resource "scaleway_instance_volume" "nfs_data" {
  name       = "${var.cluster_name}-nfs-data"
  type       = "b_ssd"
  size_in_gb = var.workdir_size_gb + var.reference_size_gb
  zone       = var.scaleway_zone
}

resource "scaleway_instance_server" "nfs_server" {
  name  = "${var.cluster_name}-nfs"
  type  = "BASIC3-X2C-4G"
  image = "ubuntu_jammy"
  zone  = var.scaleway_zone
  tags  = concat(var.tags, ["role=nfs-server"])

  additional_volume_ids = [scaleway_instance_volume.nfs_data.id]

  # cloud-init : formater le volume de données, monter, configurer le serveur NFS.
  user_data = {
    "cloud-init" = <<-EOT
      #cloud-config
      packages:
        - nfs-kernel-server
        - xfsprogs
      runcmd:
        - |
          # Détecter le volume de données (le plus grand disque non-root)
          DATA_DEV=""
          for dev in /dev/sdb /dev/vdb /dev/xvdb /dev/sdc /dev/vdc; do
            if [ -b "$dev" ]; then
              DATA_DEV="$dev"
              break
            fi
          done
          if [ -z "$DATA_DEV" ]; then
            echo "ERREUR: volume de données introuvable" >&2
            exit 1
          fi
          echo "Volume de données : $DATA_DEV"
          # Formater seulement si le volume n'est pas déjà formaté
          if ! blkid "$DATA_DEV" >/dev/null 2>&1; then
            mkfs.xfs -f "$DATA_DEV"
          fi
          mkdir -p /data
          echo "$DATA_DEV /data xfs defaults,nofail 0 2" >> /etc/fstab
          mount -a
          mkdir -p /data/workdir /data/reference
          chmod 777 /data/workdir /data/reference
        - |
          # Exports NFS — accès depuis le réseau privé (172.16.8.0/22)
          cat > /etc/exports <<'EXPORTS'
          /data/workdir 172.16.0.0/12(rw,sync,no_subtree_check,no_root_squash)
          /data/reference 172.16.0.0/12(rw,sync,no_subtree_check,no_root_squash)
          EXPORTS
          exportfs -ar
          systemctl enable nfs-kernel-server
          systemctl restart nfs-kernel-server
          echo "Serveur NFS prêt."
    EOT
  }

  depends_on = [scaleway_instance_volume.nfs_data]
}

# Attache le serveur NFS au Private Network du cluster Kapsule.
resource "scaleway_instance_private_nic" "nfs_server" {
  server_id          = scaleway_instance_server.nfs_server.id
  private_network_id = scaleway_vpc_private_network.main.id
  zone               = var.scaleway_zone
}

# Récupère l'IP privée du serveur NFS sur le Private Network via l'IPAM Scaleway.
data "scaleway_ipam_ip" "nfs_server" {
  resource {
    id   = scaleway_instance_server.nfs_server.id
    type = "instance_server"
  }
  private_network_id = scaleway_vpc_private_network.main.id

  depends_on = [scaleway_instance_private_nic.nfs_server]
}

# ── Object Storage S3 — données long terme ────────────────────────────────────
locals {
  data_buckets = {
    input   = "fastq-input"
    results = "pipeline-results"
  }
}

resource "scaleway_object_bucket" "data" {
  for_each = local.data_buckets

  name   = "${var.cluster_name}-${each.key}"
  region = var.scaleway_region
  tags   = { purpose = each.value, project = "nf-rnaseq" }

  versioning {
    enabled = false
  }
}

resource "scaleway_object_bucket_acl" "data" {
  for_each = local.data_buckets

  bucket = scaleway_object_bucket.data[each.key].name
  acl    = "private"
}
