# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Ce que ce POC déploie

Infrastructure cloud-native sur **Scaleway Kapsule** pour exécuter le pipeline bioinformatique **nf-core/rnaseq** (aligneur STAR) sur des données FASTQ single-cell issues d'un séquenceur **Illumina NovaSeq 6000 S4**.

Charge cible : 300-400 échantillons par run, **10 jobs STAR simultanés** (160 vCPU + 450 GB RAM en pic), 2,2 To de FASTQ en entrée, 1,5 To de résultats en sortie.

## Commandes

```bash
# Prérequis : copier et remplir les credentials
cp terraform/terraform.tfvars.example terraform/terraform.tfvars

make init           # terraform init
make cluster        # Déployer cluster + pools + SFS + S3 + IAM + K8s resources
make kubeconfig     # scw k8s kubeconfig install → ~/.kube/config-nf-kapsule

make upload-reference   # Générer l'index STAR GRCh38 dans le PVC reference (one-shot, ~4-6h)
make run-pipeline       # Lancer nf-core/rnaseq via Nextflow executor k8s
make status             # État nœuds + PVCs + pods
make clean              # terraform destroy

# Diagnostic
make watch-nodes    # Surveiller les nœuds compute qui scale up/down
make watch-pods     # Pods du namespace bioinformatics
make scale-check    # État du Cluster Autoscaler
```

KUBECONFIG est toujours `~/.kube/config-nf-kapsule`. Le Makefile l'exporte automatiquement.

## Architecture

### Terraform (`terraform/`)

| Fichier | Rôle |
|---|---|
| `main.tf` | Providers (scaleway ≥ 2.50, kubernetes ≥ 2.28) ; kubeconfig `~/.kube/config-nf-kapsule` ; depends_on les deux pools |
| `cluster.tf` | VPC + Private Network + Kapsule (Cilium, k8s 1.32) + autoscaler_config (scale-to-zero agressif) |
| `node_pools.tf` | Pool `orchestrator` (BASIC3-X4C-16G, min=1, toujours actif) + pool `star-compute` (MEMORY3-X64C-512G, min=0, autoscale, taint `workload=star-compute:NoSchedule`) |
| `storage.tf` | 2 volumes SFS NFS RWX (workdir 2 To, reference 500 Go) + 2 buckets S3 (input FASTQ, results BAM) |
| `iam.tf` | Application IAM `nextflow-pipeline` + API key + policy S3 + Secret Manager |
| `kubernetes.tf` | Namespace `bioinformatics`, ServiceAccount `nextflow` + ClusterRole, PV/PVC statiques NFS (SFS), StorageClass `star-scratch` (SBS dynamique RWO), Secret K8s credentials S3, ConfigMap nextflow.config |
| `variables.tf` | Variables : instance types, tailles SFS, max nœuds compute |
| `outputs.tf` | cluster_id, endpoints SFS, noms buckets, quickstart |

### Node pools

**orchestrator** (`BASIC3-X4C-16G`, 4 vCPU / 16 GB) :
- Nextflow head job, toujours actif (min=1)
- Pas de taint — pods sans contrainte s'y exécutent

**star-compute** (`MEMORY3-X64C-512G`, 64 vCPU / 512 GB) :
- Série MEMORY3 : ratio 8 GB/vCPU, idéal pour STAR (OOM stricte à 40 GB minimum)
- Packing : **4 jobs STAR par nœud** (16 vCPU × 4 = 64, 48 GB × 4 = 192 GB < 512 GB)
- Scale-to-zero entre les runs (Scaleway Kapsule n'a pas de Spot — c'est l'économie équivalente)
- Taint `workload=star-compute:NoSchedule` : seuls les pods avec tolération explicite s'y placent

### Stockage

| Volume | Type | Capacité | Mode | Usage |
|---|---|---|---|---|
| `nf-workdir-pvc` | SFS NFS | 2 To | RWX | Nextflow workdir + SAM/BAM temporaires STAR |
| `nf-reference-pvc` | SFS NFS | 500 Go | RWX | Index STAR GRCh38 (~32 Go) + GTF + extras |
| `star-scratch` | SBS dynamique | 2 To / job | RWO | Upgrade prod haute IOPS (optionnel POC) |
| `nf-kapsule-input` | S3 | illimité | — | FASTQ bruts (2,2 To par run S4) |
| `nf-kapsule-results` | S3 | illimité | — | BAM triés + count tables (1,5 To par run) |

**Performance SBS VirtioFS (Scaleway)** : 2 To → 25 687 IOPS / 201,5 MB/s (limite produit).
Pour le POC, les SAM temporaires vont dans le workdir NFS (SFS). En production, activer les PVC SBS dynamiques (`star-scratch`) via la StorageClass déjà provisionnée — décommenter le bloc `volumeClaim` dans `nextflow/nextflow.config`.

### Nextflow (`nextflow/`)

`nextflow.config` — profil `scaleway_kapsule` :
- Executor `k8s`, namespace `bioinformatics`, ServiceAccount `nextflow`
- `STAR_ALIGN` : 16 vCPU, 48 GB, nodeSelector pool `star-compute`, tolération taint, volume reference en RO, credentials S3 via Secret
- `STAR_GENOMEGENERATE` : 16 vCPU, 120 GB (génération one-shot d'index), volume reference en RW
- Endpoint S3 Scaleway configuré dans le bloc `aws.client`

`params.yaml` — paramètres par run : samplesheet, génome, outdir, read_length, strandedness.

## Contraintes critiques

- **STAR OOM** : 40 GB minimum stricts par job. Les instances MEMORY3-X (8 GB/vCPU) sont le seul choix viable sur Scaleway pour tenir 4 jobs/nœud.
- **Pas de Spot sur Kapsule** : le Cluster Autoscaler scale à 0 entre les runs. Nextflow `-resume` gère les interruptions.
- **SFS endpoint** : l'attribut `scaleway_file_system.*.endpoint` retourne l'IP privée NFS. Vérifier avec `terraform output sfs_workdir_endpoint` si le PV ne se bind pas.
- **StorageClass SBS** : le provisioner dans Kapsule est `bs.csi.scaleway.com` (v2). Ne pas utiliser l'ancien `csi.scaleway.com`.
- **Label pool Kapsule** : les nœuds reçoivent automatiquement `k8s.scaleway.com/pool-name=<pool-name>` — c'est ce label qui est utilisé dans les `nodeSelector` du nextflow.config.
- **Index STAR pré-généré** : pointer `--star_index /data/reference/star_index/GRCh38_150bp` dans `params.yaml` après `make upload-reference` pour éviter de regénérer l'index à chaque run.
- **Destroy** : `delete_additional_resources = true` dans le cluster Kapsule supprime LBs, IPs et volumes K8s créés dynamiquement lors du `make clean`.
