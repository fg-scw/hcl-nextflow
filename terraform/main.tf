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

locals {
  kubeconfig = yamldecode(data.scaleway_k8s_cluster.main.kubeconfig[0].config_file)
  kube_host  = local.kubeconfig.clusters[0].cluster.server
  kube_token = local.kubeconfig.users[0].user.token
  kube_ca    = local.kubeconfig.clusters[0].cluster["certificate-authority-data"]
}

resource "local_file" "kubeconfig" {
  content         = data.scaleway_k8s_cluster.main.kubeconfig[0].config_file
  filename        = pathexpand("~/.kube/config-nf-kapsule")
  file_permission = "0600"
}

provider "kubernetes" {
  host                   = local.kube_host
  token                  = local.kube_token
  cluster_ca_certificate = base64decode(local.kube_ca)
}
