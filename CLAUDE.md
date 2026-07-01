# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Ce que ce POC déploie

Infrastructure cloud-native sur **Scaleway Kapsule** pour exécuter le pipeline bioinformatique **nf-core/rnaseq** (aligneur STAR) sur des données FASTQ issues d'un séquenceur **Illumina NovaSeq 6000 S4**.

Charge cible : 300-400 échantillons par run, **10 jobs STAR simultanés** (80 vCPU + 520 GB RAM en pic), 2,2 To de FASTQ en entrée, 1,5 To de résultats en sortie.

## Prérequis

`terraform ≥ 1.5`, `scw` (Scaleway CLI configuré), `aws` CLI, `kubectl`, `curl`, `jq`.

## Commandes

```bash
# Prérequis : copier et remplir les credentials
cp terraform/terraform.tfvars.example terraform/terraform.tfvars

make init              # terraform init
make cluster           # Déployer cluster + pools + SFS + S3 + IAM + K8s resources (3 phases, ~15-20 min)
make deploy-and-smoke  # init + cluster + smoke-test en une commande
make kubeconfig        # scw k8s kubeconfig install → ~/.kube/config-nf-kapsule

make smoke-test        # Valider S3 → Kapsule → nf-core/rnaseq → S3 (dataset officiel nf-core GSE110004)
make upload-reference  # Générer l'index STAR GRCh38 dans le PVC reference (one-shot, ~4-6h)
make run-pipeline      # Lancer nf-core/rnaseq via Nextflow executor k8s
make status            # État nœuds + PVCs + pods

make clean             # terraform destroy (⚠ supprime cluster et données S3)

# Diagnostic
make watch-nodes       # Surveiller les nœuds compute qui scale up/down
make watch-pods        # Pods du namespace bioinformatics
make scale-check       # État du Cluster Autoscaler
make logs-autoscaler   # Logs du Cluster Autoscaler
make fmt               # terraform fmt -recursive
make outputs           # Afficher tous les outputs Terraform
```

KUBECONFIG est toujours `~/.kube/config-nf-kapsule`. Le Makefile l'exporte automatiquement.

## Architecture

### Terraform (`terraform/`)

| Fichier | Rôle |
|---|---|
| `main.tf` | Providers (scaleway ≥ 2.50, kubernetes ≥ 2.28) ; kubeconfig `~/.kube/config-nf-kapsule` |
| `cluster.tf` | VPC + Private Network + Kapsule (Cilium, k8s 1.35.3) + autoscaler_config scale-to-zero |
| `node_pools.tf` | Pool `orchestrator` (POP2-4C-16G, min=1) + pool `star-compute` (POP2-HM-8C-64G, min=0, taint `workload=star-compute:NoSchedule`) |
| `storage.tf` | Buckets S3 input FASTQ + results BAM |
| `kubernetes.tf` | Namespace `bioinformatics`, ServiceAccount `nextflow` + ClusterRole, PV/PVC SFS (sfs-standard, RWX), StorageClass `star-scratch` (SBS dynamique RWO), Secret K8s credentials S3, ConfigMap nextflow.config |
| `iam.tf` | Application IAM `nextflow-pipeline` + API key + policy S3 + Secret Manager |
| `variables.tf` | Instance types, tailles SFS, max nœuds compute |
| `outputs.tf` | cluster_id, noms buckets, quickstart |

### Node pools

**orchestrator** (`POP2-4C-16G`, 4 vCPU / 16 GB) :
- Nextflow head job, toujours actif (min=1)
- Pas de taint

**star-compute** (`POP2-HM-8C-64G`, 8 vCPU / 64 GB) :
- Famille POP2 **requise** pour le driver CSI SFS (`filestorage.csi.scaleway.com`)
- Packing POC : **1 job STAR par nœud** (7 vCPU + 52 GB par job — 1 cœur réservé K8s)
- Scale-to-zero entre les runs ; Nextflow `-resume` gère les interruptions
- Taint `workload=star-compute:NoSchedule`
- Packing production : `POP2-HM-16C-128G` (2 jobs/nœud) ou `POP2-HM-32C-256G` (4 jobs/nœud)

### Stockage

| Volume | Type | Capacité | Mode | Usage |
|---|---|---|---|---|
| `nf-workdir-pvc` | SFS (`sfs-standard`) | 2 To | RWX | Nextflow workdir + SAM/BAM temporaires STAR |
| `nf-reference-pvc` | SFS (`sfs-standard`) | 500 Go | RWX | Index STAR GRCh38 (~32 Go) + GTF + extras |
| `nf-kapsule-input` | S3 | illimité | — | FASTQ bruts (2,2 To par run S4) |
| `nf-kapsule-results` | S3 | illimité | — | BAM triés + count tables (1,5 To par run) |
| `star-scratch` | SBS dynamique | 2 To / job | RWO | Upgrade prod haute IOPS (optionnel POC) |

Les PVCs SFS sont provisionnées dynamiquement via le CSI driver natif Kapsule activé par le tag `scw-filestorage-csi` au niveau du cluster. Vérifier après déploiement : `kubectl get daemonset -n kube-system filestorage-csi-node`.

**Scratch SBS (production)** : décommenter le bloc `volumeClaim` dans `withName:STAR_ALIGN` de `nextflow/nextflow.config` et supprimer `scratch = true`.

### Scripts (`scripts/`)

| Script | Usage |
|---|---|
| `launch-nextflow-job.sh` | Lib commune : crée le Job K8s head Nextflow (sourcé par smoke-test et run-pipeline) |
| `smoke-test.sh` | Télécharge GSE110004/SRR6357070, upload S3, lance nf-core/rnaseq, vérifie le MultiQC en sortie |
| `run-pipeline.sh` | Lance nf-core/rnaseq sur les vrais FASTQ avec `nextflow/params.yaml` |
| `bootstrap-reference.sh` | Génère l'index STAR GRCh38 dans le PVC reference (one-shot) |

### Nextflow (`nextflow/`)

`nextflow.config` — profil `scaleway_kapsule` :
- Executor `k8s`, namespace `bioinformatics`, ServiceAccount `nextflow`
- `STAR_ALIGN` : 7 CPU / 52 GB, nodeSelector pool `star-compute`, tolération taint, volume reference en RO
- `STAR_GENOMEGENERATE` : 7 CPU / 56 GB (génération one-shot d'index), volume reference en RW
- Endpoint S3 Scaleway : `https://s3.fr-par.scw.cloud`

`params.yaml` — paramètres par run : `input` (samplesheet CSV sur S3), `outdir` (bucket S3 results), `read_length`, `strandedness`, `star_index` (si pré-généré).

## Contraintes critiques

- **SFS CSI + famille POP2** : le driver `filestorage.csi.scaleway.com` n'est compatible qu'avec la famille POP2. Ne pas utiliser BASIC3 ou MEMORY3.
- **Déploiement en 3 phases** : `make cluster` enchaîne Phase 0 (VPC), Phase 1 (cluster + kubeconfig), attente 60s, Phase 2 (ressources K8s). Ne pas interrompre entre phases.
- **Provider kubernetes lit `~/.kube/config-nf-kapsule`** : ce fichier est installé par la CLI `scw` entre Phase 1 et Phase 2, hors graphe Terraform. En cas de remplacement Kapsule, relancer `make cluster`.
- **STAR OOM** : 40 GB minimum stricts par job (index GRCh38 chargé intégralement en RAM). STAR échoue sans message explicite en dessous.
- **Pas de Spot sur Kapsule** : le Cluster Autoscaler scale à 0 entre les runs. Nextflow `-resume` gère les reprises.
- **`delete_additional_resources = false`** dans `cluster.tf` : un remplacement Kapsule ne supprime pas le Private Network géré par Terraform.
- **Label pool Kapsule** : les nœuds reçoivent automatiquement `k8s.scaleway.com/pool-name=<pool-name>` — utilisé dans les `nodeSelector` de `nextflow.config`.
- **Index STAR pré-généré** : après `make upload-reference`, pointer `star_index: "/data/reference/star_index/GRCh38_150bp"` dans `params.yaml`.
- **Destroy** : les buckets S3 sont détruits avec leur contenu (`force_destroy = true`). Sauvegarder les résultats avant `make clean`.
