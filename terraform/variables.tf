# ── Credentials ───────────────────────────────────────────────────────────────
variable "scw_access_key" {
  type      = string
  sensitive = true
}
variable "scw_secret_key" {
  type      = string
  sensitive = true
}
variable "scw_project_id" {
  type = string
}

# ── Infrastructure ────────────────────────────────────────────────────────────
variable "cluster_name" {
  type    = string
  default = "nf-kapsule"
  validation {
    condition     = can(regex("^[a-z0-9-]{2,32}$", var.cluster_name))
    error_message = "Must be 2-32 lowercase alphanumeric or hyphens."
  }
}
variable "scaleway_region" {
  type    = string
  default = "fr-par"
}
variable "scaleway_zone" {
  type    = string
  default = "fr-par-1"
}
variable "k8s_version" {
  type        = string
  default     = "1.35.3"
  description = "Version Kubernetes Kapsule. Versions disponibles : scw k8s version list region=fr-par"
}
variable "vpc_cidr" {
  type    = string
  default = "172.16.8.0/22"
}

# ── Node pools ────────────────────────────────────────────────────────────────
variable "orchestrator_node_type" {
  type        = string
  default     = "POP2-4C-16G"
  description = "Nextflow head job : 4 vCPU / 16 GB POP2, toujours actif (min=1). POP2 requis pour le CSI File Storage (SFS)."
}

variable "compute_node_type" {
  type        = string
  default     = "POP2-HM-8C-64G"
  description = <<-EOD
    Nœud STAR-compute : 8 vCPU / 64 GB RAM, série POP2 High Memory (requis pour SFS CSI).
    Packing POC : 1 job STAR par nœud à 8 vCPU / 52 GB.
    Alternative production (meilleur packing) : POP2-HM-16C-128G (2 jobs/nœud) ou POP2-HM-32C-256G (4 jobs/nœud).
    BASIC3/MEMORY3 documentés pour une future implémentation sans SFS.
  EOD
}

variable "compute_max_nodes" {
  type        = number
  default     = 10
  description = "Max nœuds compute : 10 × 1 job = 10 slots STAR simultanés (pic cible du run)."
  validation {
    condition     = var.compute_max_nodes >= 1 && var.compute_max_nodes <= 20
    error_message = "compute_max_nodes doit être entre 1 et 20."
  }
}

# ── Storage ───────────────────────────────────────────────────────────────────
variable "workdir_size_gb" {
  type        = number
  default     = 2000
  description = <<-EOD
    SFS workdir (NFS RWX) — Nextflow work directory + temp STAR files.
    Dimensionnement : 10 jobs × 60 GB (SAM temp) = 600 GB peak → 2 TB avec marge.
    Performance VirtioFS SBS sous-jacent : ~25 000 IOPS / 200 MB/s par tranche de 2 TB.
  EOD
}

variable "reference_size_gb" {
  type        = number
  default     = 500
  description = "SFS reference (NFS RWX) — index STAR GRCh38 (~32 GB) + annotations + extras. 500 GB pour plusieurs génomes."
}

variable "star_scratch_size_gi" {
  type        = number
  default     = 2000
  description = <<-EOD
    Taille du PVC SBS par job STAR (scratch haute IOPS, RWO dynamique).
    2 TB → 25 687 IOPS / 201,5 MB/s (max produit VirtioFS Scaleway pour 2 TB).
    Activé via StorageClass 'star-scratch' — optionnel pour le POC, recommandé en prod.
  EOD
}

# ── Tags ──────────────────────────────────────────────────────────────────────
variable "tags" {
  type    = list(string)
  default = ["env=poc", "project=nf-rnaseq", "pipeline=nf-core-rnaseq", "owner=hcl"]
}
