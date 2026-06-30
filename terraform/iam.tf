# ── Application IAM dédiée au pipeline Nextflow ───────────────────────────────
#
# Scaleway Kapsule ne fournit pas d'identité workload type IRSA/Workload Identity.
# On utilise une clé statique dédiée au pipeline, stockée dans Secret Manager
# et injectée comme Secret Kubernetes dans le namespace bioinformatics.
# Rotation à prévoir hors scope de ce POC.

resource "scaleway_iam_application" "nextflow_pipeline" {
  name        = "${var.cluster_name}-pipeline"
  description = "Nextflow nf-core/rnaseq — lecture bucket FASTQ input + écriture bucket results"
  tags        = var.tags
}

resource "scaleway_iam_api_key" "nextflow_pipeline" {
  application_id     = scaleway_iam_application.nextflow_pipeline.id
  default_project_id = var.scw_project_id
  description        = "Pipeline S3 API key — Nextflow executor k8s"
}

resource "scaleway_iam_policy" "nextflow_pipeline_s3" {
  name           = "${var.cluster_name}-pipeline-s3"
  description    = "Lecture FASTQ input + écriture résultats pipeline"
  application_id = scaleway_iam_application.nextflow_pipeline.id
  tags           = var.tags

  rule {
    project_ids = [var.scw_project_id]
    permission_set_names = [
      "ObjectStorageObjectsRead",
      "ObjectStorageObjectsWrite",
      "ObjectStorageObjectsDelete",
      "ObjectStorageBucketsRead",
    ]
  }
}

# ── Secret Manager — credentials injectés dans le cluster ────────────────────
resource "scaleway_secret" "pipeline_credentials" {
  name        = "${var.cluster_name}-pipeline-s3-credentials"
  path        = "/nf-rnaseq"
  description = "Credentials IAM S3 pour le pipeline nf-core/rnaseq"
  type        = "key_value"
  project_id  = var.scw_project_id
  region      = var.scaleway_region
  tags        = var.tags
}

resource "scaleway_secret_version" "pipeline_credentials" {
  secret_id = scaleway_secret.pipeline_credentials.id
  region    = var.scaleway_region

  data = jsonencode({
    access_key     = scaleway_iam_api_key.nextflow_pipeline.access_key
    secret_key     = scaleway_iam_api_key.nextflow_pipeline.secret_key
    region         = var.scaleway_region
    s3_endpoint    = "https://s3.${var.scaleway_region}.scw.cloud"
    input_bucket   = scaleway_object_bucket.data["input"].name
    results_bucket = scaleway_object_bucket.data["results"].name
  })
}
