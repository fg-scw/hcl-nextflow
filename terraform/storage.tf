# ── Object Storage S3 — données long terme ────────────────────────────────────
#
# Le serveur NFS est désormais déployé en cluster (kubernetes.tf) avec un PVC
# scw-bssd pour éviter la dépendance sur scaleway_block_volume_attachment
# (non disponible dans le provider 2.76).

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
