output "cluster_id" {
  value       = split("/", scaleway_k8s_cluster.main.id)[1]
  description = "ID Kapsule — utilisé par 'scw k8s kubeconfig install'"
}

output "kubeconfig_path" {
  value = local_file.kubeconfig.filename
}

output "workdir_pvc" {
  value       = kubernetes_persistent_volume_claim.workdir.metadata[0].name
  description = "PVC SFS workdir (sfs-standard, RWX) — Nextflow workdir partagé entre tous les pods task"
}

output "reference_pvc" {
  value       = kubernetes_persistent_volume_claim.reference.metadata[0].name
  description = "PVC SFS reference (sfs-standard, RWX) — index STAR GRCh38 + GTF"
}

output "input_bucket_name" {
  value       = scaleway_object_bucket.data["input"].name
  description = "Bucket S3 pour les FASTQ d'entrée (2,2 To par run)"
}

output "results_bucket_name" {
  value       = scaleway_object_bucket.data["results"].name
  description = "Bucket S3 pour les résultats pipeline (BAM + count tables)"
}

output "pipeline_credentials_secret_id" {
  value       = scaleway_secret.pipeline_credentials.id
  description = "Secret Manager — credentials IAM S3 du pipeline"
}

output "pipeline_iam_app_id" {
  value       = scaleway_iam_application.nextflow_pipeline.id
  description = "Application IAM Nextflow pipeline"
}

output "compute_pool_status" {
  value       = scaleway_k8s_pool.star_compute.status
  description = "État du pool star-compute (autoscale 0→N, voir variable compute_max_nodes)"
}

output "quickstart" {
  value = <<-EOT

    ╔══════════════════════════════════════════════════════════════════╗
    ║  nf-core/rnaseq sur Scaleway Kapsule — Commandes de démarrage   ║
    ╚══════════════════════════════════════════════════════════════════╝

    # 1. Configurer kubectl
    CLUSTER_ID=$(terraform -chdir=terraform output -raw cluster_id)
    scw k8s kubeconfig install $CLUSTER_ID --filepath ~/.kube/config-nf-kapsule
    export KUBECONFIG=~/.kube/config-nf-kapsule
    kubectl get nodes

    # 2. Vérifier le driver SFS CSI et les PVCs
    kubectl get daemonset -n kube-system filestorage-csi-node
    kubectl get pvc -n bioinformatics

    # 3. Uploader l'index STAR dans le volume référence (one-shot)
    make upload-reference

    # 4. Uploader les FASTQ dans le bucket input
    aws --endpoint-url https://s3.fr-par.scw.cloud s3 sync \
      /local/fastq/ s3://${scaleway_object_bucket.data["input"].name}/

    # 5. Lancer le pipeline
    make run-pipeline

    # 6. Surveiller les nœuds compute (autoscaling)
    make watch-nodes

  EOT
}
