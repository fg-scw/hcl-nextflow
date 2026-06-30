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
  }
}

provider "scaleway" {
  access_key = var.scw_access_key
  secret_key = var.scw_secret_key
  project_id = var.scw_project_id
  region     = var.scaleway_region
  zone       = var.scaleway_zone
}

# Le Makefile installe ce kubeconfig entre les phases Scaleway et Kubernetes.
# Il reste volontairement hors du graphe Terraform : remplacer un local_file pendant
# l'apply supprimerait temporairement le fichier et ferait retomber ce provider sur
# localhost:80.
provider "kubernetes" {
  config_path = pathexpand("~/.kube/config-nf-kapsule")
}
