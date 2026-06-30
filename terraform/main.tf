terraform {
  required_version = ">= 1.5.0"

  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = ">= 2.50"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.28"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.0"
    }
  }
}

provider "scaleway" {
  access_key = var.scw_access_key
  secret_key = var.scw_secret_key
  project_id = var.scw_project_id
  region     = var.scaleway_region
  zone       = var.scaleway_zone
}

# Lecture du kubeconfig après que les deux pools soient prêts.
data "scaleway_k8s_cluster" "main" {
  cluster_id = scaleway_k8s_cluster.main.id
  depends_on = [
    scaleway_k8s_pool.orchestrator,
    scaleway_k8s_pool.star_compute,
  ]
}

resource "local_file" "kubeconfig" {
  content         = data.scaleway_k8s_cluster.main.kubeconfig[0].config_file
  filename        = pathexpand("~/.kube/config-nf-kapsule")
  file_permission = "0600"
}

# Le provider K8s lit le fichier kubeconfig écrit par Phase 1 (local_file.kubeconfig).
# Ne pas utiliser de locals/data source ici : au moment où Terraform initialise le
# provider en Phase 2, le data source scaleway_k8s_cluster peut retourner un
# kubeconfig vide si le control plane vient juste de démarrer → host = null → localhost.
# Le fichier sur disque, lui, est stable dès la fin de Phase 1.
provider "kubernetes" {
  config_path = pathexpand("~/.kube/config-nf-kapsule")
}
