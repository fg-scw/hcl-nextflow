# nf-core/rnaseq sur Scaleway Kapsule

Pipeline bioinformatique **nf-core/rnaseq v3.14.0** (aligneur STAR + Salmon) déployé sur **Scaleway Kapsule** (Kubernetes managé). Infrastructure complète provisionnée par Terraform : cluster, node pools, stockage NFS in-cluster, buckets S3, IAM.

**Charge cible** : 300-400 échantillons/run · 10 jobs STAR simultanés · 80 vCPU + 520 GB RAM en pic · 2,2 To FASTQ → 1,5 To BAM

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  Scaleway Kapsule — namespace bioinformatics                         │
│                                                                      │
│  Pool orchestrator (POP2-4C-16G, min=1, toujours actif)             │
│  ┌──────────────────────────────────────────────────────────┐        │
│  │  Nextflow head job                                       │        │
│  │  (pilote le pipeline via executor k8s)                   │        │
│  └──────────────────────────────────────────────────────────┘        │
│                │ k8s executor                                        │
│  Pool star-compute (POP2-HM-8C-64G, min=0, autoscale 0→10)          │
│  ┌──────────────────────────────────────────────────────────┐        │
│  │  STAR job ×1   STAR job ×1   STAR job ×1                │        │
│  │  8vCPU/52GB    8vCPU/52GB    8vCPU/52GB                 │        │
│  └──────────────────────────────────────────────────────────┘        │
└──────────────────────────────────────────────────────────────────────┘
         │ S3 input/output              │ SFS RWX (filestorage CSI)
  ┌──────┴───────┐            ┌─────────┴──────────┐
  │  S3 FASTQ    │            │  sfs-standard PVC  │
  │  S3 results  │            │  nf-workdir-pvc    │
  └──────────────┘            │  nf-reference-pvc  │
                              └────────────────────┘
```

| Pool | Instance | vCPU | RAM | Rôle | Autoscale |
|---|---|---|---|---|---|
| `orchestrator` | POP2-4C-16G | 4 | 16 GB | Nextflow head job + tâches légères | min=1, toujours actif |
| `star-compute` | POP2-HM-8C-64G | 8 | 64 GB | 1 job STAR par nœud | min=0, scale-to-zero, max=10 |

| Volume | Type | Capacité | Mode | Usage |
|---|---|---|---|---|
| `nf-workdir-pvc` | SFS (`sfs-standard`) | 2 To | RWX | Nextflow workdir + BAM temporaires |
| `nf-reference-pvc` | SFS (`sfs-standard`) | 500 Go | RWX | Génome GRCh38 + GTF Ensembl 110 |
| `nf-kapsule-input` | S3 | illimité | — | FASTQ bruts (2,2 To par run NovaSeq S4) |
| `nf-kapsule-results` | S3 | illimité | — | BAM triés + matrices de comptage + MultiQC |

---

## Prérequis

- Terraform ≥ 1.5
- Scaleway CLI (`scw`) configuré
- AWS CLI (`aws`)
- `curl`, `jq`, `kubectl`
- Compte Scaleway avec accès au projet cible

---

## Commandes

```bash
make init              # terraform init
make cluster           # Déployer toute l'infrastructure (~15-20 min)
make deploy-and-smoke  # init + cluster + smoke test en une commande
make kubeconfig        # Installer le kubeconfig → ~/.kube/config-nf-kapsule
make status            # État nœuds + PVCs + pods
make upload-reference  # Télécharger génome GRCh38 + GTF sur le PVC reference (one-shot, ~1h)
make prepare-demo      # Télécharger SRR1039508 (human, GRCh38) et uploader dans S3
make smoke-test        # Smoke test automatique nf-core (dataset officiel)
make run-pipeline      # Lancer nf-core/rnaseq sur le cluster Kapsule
make watch-nodes       # Surveiller les nœuds compute (autoscaling)
make watch-pods        # Pods du namespace bioinformatics en temps réel
make scale-check       # État du Cluster Autoscaler
make logs-autoscaler   # Logs du Cluster Autoscaler
make outputs           # Afficher les outputs Terraform (buckets, etc.)
make clean             # terraform destroy (⚠ supprime cluster et données S3)
```

Java et Nextflow ne sont pas requis en local — `make run-pipeline` crée un Job head dans le pool `orchestrator` avec l'image `nextflow/nextflow:25.10.4`.

---

## Workflow complet bout-en-bout

### 1. Déployer l'infrastructure

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Remplir : scw_access_key, scw_secret_key, scw_project_id

make init
make cluster     # ~15-20 min (3 phases Terraform automatiques)
make kubeconfig
kubectl get nodes
kubectl get pvc -n bioinformatics   # nf-workdir-pvc et nf-reference-pvc doivent être Bound
```

Résultats observés (2026-07-01) :

```
NAME                                             STATUS   ROLES    AGE
scw-nf-kapsule-kapsule-orchestrator-b2ea2ad2a2   Ready    <none>   15m

NAME                STATUS   CAPACITY   ACCESS MODES
nf-workdir-pvc      Bound    2000Gi     RWX
nf-reference-pvc    Bound    500Gi      RWX
```

### 2. Télécharger la référence GRCh38

```bash
make upload-reference   # ~1h — génome.fa + genes.gtf sur nf-reference-pvc
```

Cette étape est **one-shot** : les fichiers restent sur le PVC entre les runs.

> Le script télécharge le génome primaire Ensembl 110 et le GTF. L'index STAR lui-même est généré automatiquement par nf-core au premier `make run-pipeline` (voir [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — bug #7 pour le détail de compatibilité des versions STAR).

### 3. Préparer les données

```bash
make prepare-demo   # ~5 min — télécharge SRR1039508 (human airway, HiSeq 2000, 50K reads PE)
                    # et uploade dans s3://<input-bucket>/ avec samplesheet.csv
```

Pour les vrais FASTQs NovaSeq, uploader directement dans S3 et adapter `nextflow/params.yaml` (`input`, `outdir`).

> Les FASTQs du smoke test nf-core (`SRR6357070`) sont de la levure (*S. cerevisiae*, taxid|4932) et ne s'alignent pas sur GRCh38. Utiliser `make prepare-demo` ou un dataset humain réel.

### 4. Lancer le pipeline

```bash
make run-pipeline   # ~15 min sur le dataset SRR1039508
```

Séquence d'exécution observée :

| Heure | Étape | Résultat | Pool |
|---|---|---|---|
| 18:47 | Job head Nextflow démarré | Pod Running | orchestrator |
| 18:49 | `PREPARE_GENOME` (GTF_FILTER, GETCHROMSIZES, GTF2BED, MAKE_TRANSCRIPTS_FASTA) | ✔ | orchestrator |
| 18:49 | `FASTQC`, `TRIMGALORE` | ✔ | orchestrator |
| 18:51 | `STAR_GENOMEGENERATE_IGENOMES` | ✔ — nœud star-compute provisionné | star-compute |
| 18:51 | `STAR_ALIGN_IGENOMES` | Running — RAM pic **35 GB** (index GRCh38 chargé) | star-compute |
| 18:55 | `STAR_ALIGN_IGENOMES` | ✔ — BAM produit avec reads alignés | star-compute |
| 18:56 | `SAMTOOLS_SORT`, `SAMTOOLS_INDEX`, `SALMON_QUANT` | ✔ | star-compute |
| 18:57–19:02 | QC (RSeQC, DupRadar, Qualimap, FeatureCounts, StringTie, MultiQC…) | ✔ ×32 tâches | orchestrator |
| **19:03** | **Pipeline terminé** | **44 tâches succeeded** | — |

Résumé Nextflow :

```
-[nf-core/rnaseq] Pipeline completed successfully -
Completed at : 01-Jul-2026 17:03:27
Duration     : 15m 37s
CPU hours    : 1.1
Succeeded    : 44
```

Sorties S3 :

```
star_salmon/SRR1039508.markdup.sorted.bam
star_salmon/SRR1039508/quant.sf
star_salmon/salmon.merged.gene_counts.tsv
star_salmon/salmon.merged.gene_tpm.tsv
multiqc/star_salmon/multiqc_report.html   ← rapport QC agrégé
```

Pour reprendre après interruption : `NXF_RESUME=1 make run-pipeline`

---

## Structure du repo

```
terraform/
  main.tf             # Providers (scaleway ≥ 2.50, kubernetes ≥ 2.28), kubeconfig
  cluster.tf          # VPC + Private Network + Kapsule (Cilium, k8s 1.35.3)
  node_pools.tf       # Pool orchestrator + pool star-compute (taint, autoscale)
  storage.tf          # Buckets S3 input/results
  kubernetes.tf       # PVCs SFS, RBAC, StorageClass, Secret, ConfigMap nextflow.config
  iam.tf              # Application IAM nextflow + API key + policy S3
  variables.tf        # Instance types, tailles stockage, max nœuds
  outputs.tf          # Buckets, cluster_id, quickstart
  terraform.tfvars.example

nextflow/
  nextflow.config     # Profil scaleway_kapsule (executor k8s, ressources par process)
  params.yaml         # Paramètres par run (input, outdir, fasta, gtf, aligner)

scripts/
  bootstrap-reference.sh   # Téléchargement génome GRCh38 + GTF sur nf-reference-pvc
  prepare-demo.sh          # Téléchargement SRR1039508 + upload S3 + samplesheet
  launch-nextflow-job.sh   # Lib commune : crée le Job K8s head Nextflow
  smoke-test.sh            # Smoke test automatique (dataset nf-core officiel)
  run-pipeline.sh          # Lance nf-core/rnaseq via Nextflow executor k8s
```

---

## Teardown

```bash
make clean   # terraform destroy — supprime cluster, nœuds, PVCs SFS, buckets S3
```

> Les buckets S3 sont détruits avec leur contenu (`force_destroy = true`). Sauvegarder les résultats avant `make clean`.

---

Pour le détail des problèmes rencontrés lors de la validation, les contraintes de déploiement, et les recommandations de dimensionnement pour la production : voir **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)**.
