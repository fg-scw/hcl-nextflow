# ── Scaleway File Storage (SFS) — NFS RWX ─────────────────────────────────────
#
# SFS est basé sur VirtioFS (même technologie que SBS block).
# Les volumes SFS sont accessibles en NFS depuis les nœuds Kapsule
# dans la même zone via le réseau interne Scaleway (pas besoin de PN explicite).
#
# Performance indicative (VirtioFS SBS sous-jacent) :
#   - 2 TB : ≈ 25 687 IOPS / 201,5 MB/s (limite produit actuelle)
# Le workdir 2 TB couvre 10 jobs STAR simultanés × 60 GB SAM temp = 600 GB peak.

resource "scaleway_file_system" "workdir" {
  name = "${var.cluster_name}-workdir"
  # Taille en GB. 2 TB = 2000 GB.
  size = var.workdir_size_gb
  zone = var.scaleway_zone
  tags = concat(var.tags, ["purpose=nf-workdir"])
}

resource "scaleway_file_system" "reference" {
  name = "${var.cluster_name}-reference"
  # Index STAR GRCh38 ≈ 32 GB + GRCm39 ≈ 27 GB + annotations + extras → 500 GB.
  size = var.reference_size_gb
  zone = var.scaleway_zone
  tags = concat(var.tags, ["purpose=genome-reference"])
}

# ── Object Storage S3 — données long terme ────────────────────────────────────
#
# input   : FASTQ bruts (2,2 To par run S4 NovaSeq).
# results : BAM triés + tables de comptage (1,5 To par run).
# Les buckets sont privés ; l'accès est accordé via l'application IAM nextflow-pipeline.

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

  # Versioning désactivé pour économiser le stockage (données reproductibles depuis FASTQ).
  versioning {
    enabled = false
  }
}

resource "scaleway_object_bucket_acl" "data" {
  for_each = local.data_buckets

  bucket = scaleway_object_bucket.data[each.key].name
  acl    = "private"
}
