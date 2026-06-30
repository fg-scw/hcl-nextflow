# nf-core/rnaseq sur Scaleway Kapsule

Pipeline bioinformatique **nf-core/rnaseq** (aligneur STAR) déployé sur **Scaleway Kapsule** (Kubernetes managé). Infrastructure complète provisionnée par Terraform : cluster, node pools, stockage NFS in-cluster, buckets S3, IAM.

**Charge cible** : 300-400 échantillons/run · 10 jobs STAR simultanés · 160 vCPU + 450 GB RAM en pic · 2,2 To FASTQ → 1,5 To BAM

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  Scaleway Kapsule — namespace bioinformatics                         │
│                                                                      │
│  Pool orchestrator (BASIC3-X4C-16G, min=1, toujours actif)          │
│  ┌──────────────────────────────────────────────────────────┐        │
│  │  Nextflow head job          NFS Server pod               │        │
│  │  (pilote le pipeline)       (SBS RWO → NFS RWX)         │        │
│  └──────────────────────────────────────────────────────────┘        │
│                │ k8s executor                │ NFS mount             │
│  Pool star-compute (MEMORY3-X64C-512G, min=0, autoscale 0→5)        │
│  ┌──────────────────────────────────────────────────────────┐        │
│  │  STAR job ×4   STAR job ×4   STAR job ×4                │        │
│  │  16vCPU/48GB   16vCPU/48GB   16vCPU/48GB                │        │
│  └──────────────────────────────────────────────────────────┘        │
└──────────────────────────────────────────────────────────────────────┘
         │ S3 input/output                     │ NFS shared volumes
  ┌──────┴───────┐                    ┌────────┴────────┐
  │  S3 FASTQ    │                    │  NFS workdir    │
  │  S3 results  │                    │  NFS reference  │
  └──────────────┘                    └─────────────────┘
```

### Node pools

| Pool | Instance | vCPU | RAM | Rôle | Autoscale |
|---|---|---|---|---|---|
| `orchestrator` | BASIC3-X4C-16G | 4 | 16 GB | Nextflow head + NFS server | min=1, toujours actif |
| `star-compute` | MEMORY3-X64C-512G | 64 | 512 GB | Jobs STAR (4 par nœud) | min=0, scale-to-zero |

**Packing STAR** : 4 jobs × (16 vCPU + 48 GB) = 64 vCPU / 192 GB par nœud MEMORY3. Le ratio 8 GB/vCPU de la série MEMORY3 est le seul viable sur Scaleway pour tenir l'OOM STAR à 40 GB minimum par job.

### Stockage

| Volume | Type | Capacité | Mode | Usage |
|---|---|---|---|---|
| `nf-workdir-pvc` | SBS → NFS RWX | 2 To | ReadWriteMany | Nextflow workdir + SAM/BAM temporaires |
| `nf-reference-pvc` | SBS → NFS RWX | 500 Go | ReadWriteMany | Index STAR GRCh38 (~32 Go) + GTF |
| `nf-kapsule-input` | S3 | illimité | — | FASTQ bruts (2,2 To par run NovaSeq S4) |
| `nf-kapsule-results` | S3 | illimité | — | BAM triés + count tables |
| `star-scratch` (optionnel) | SBS RWO dynamique | 2 To/job | ReadWriteOnce | Scratch haute IOPS en production |

Le stockage partagé est implémenté via un **NFS server in-cluster** (`erichough/nfs-server`) monté sur un PVC SBS (`scw-bssd`). C'est le contournement au fait que `scaleway_file_system` (SFS managé) n'est pas disponible dans le provider Terraform Scaleway 2.x.

**Performance SBS VirtioFS** : 2 To → 25 687 IOPS / 201,5 MB/s (limite produit Scaleway).

---

## Prérequis

- Terraform ≥ 1.5
- Scaleway CLI (`scw`) configuré
- `kubectl`
- Nextflow ≥ 23.10 (pour le profil k8s)
- Un compte Scaleway avec accès au projet cible

---

## Démarrage rapide

```bash
# 1. Credentials
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Remplir : scw_access_key, scw_secret_key, scw_project_id

# 2. Déployer l'infrastructure (~10-15 min)
make init
make cluster

# 3. Configurer kubectl
make kubeconfig
kubectl get nodes

# 4. Vérifier le NFS server
kubectl get pods -n bioinformatics -l app=nfs-server
kubectl get pvc -n bioinformatics

# 5. Générer l'index STAR GRCh38 (one-shot, ~4-6h)
make upload-reference

# 6. Uploader les FASTQ dans S3
INPUT_BUCKET=$(terraform -chdir=terraform output -raw input_bucket_name)
aws --endpoint-url https://s3.fr-par.scw.cloud \
    s3 sync /local/fastq/ s3://$INPUT_BUCKET/

# 7. Adapter les paramètres du run
vi nextflow/params.yaml   # input, outdir, star_index si pré-généré

# 8. Lancer le pipeline
make run-pipeline

# 9. Surveiller le scaling
make watch-nodes   # nœuds compute qui scale up/down
make watch-pods    # pods du namespace bioinformatics
```

---

## Commandes

```bash
make init              # terraform init
make cluster           # Déployer toute l'infrastructure
make kubeconfig        # Installer le kubeconfig → ~/.kube/config-nf-kapsule
make status            # État nœuds + PVCs + pods
make upload-reference  # Générer l'index STAR dans le volume reference
make run-pipeline      # Lancer nf-core/rnaseq via Nextflow executor k8s
make watch-nodes       # Surveiller les nœuds compute (autoscaling)
make watch-pods        # Pods du namespace bioinformatics en temps réel
make scale-check       # État du Cluster Autoscaler
make logs-autoscaler   # Logs du Cluster Autoscaler
make outputs           # Afficher les outputs Terraform (buckets, IPs, etc.)
make clean             # terraform destroy (⚠ supprime cluster et données)
```

---

## Configuration Nextflow

### `nextflow/params.yaml` — paramètres par run

| Paramètre | Description |
|---|---|
| `input` | Samplesheet CSV sur S3 (`sample,fastq_1,fastq_2,strandedness`) |
| `genome` | `GRCh38` (ou utiliser `star_index` + `gtf` + `fasta` si pré-généré) |
| `outdir` | Bucket S3 results (`s3://nf-kapsule-results/run-DATE`) |
| `read_length` | Longueur de lecture NovaSeq (150 bp → sjdbOverhang=149) |
| `aligner` | `star_salmon` (STAR pour l'alignement + Salmon pour la quantification) |

### `nextflow/nextflow.config` — profil `scaleway_kapsule`

- Executor `k8s`, namespace `bioinformatics`, ServiceAccount `nextflow`
- `STAR_ALIGN` : 16 vCPU / 48 GB, `nodeSelector` pool `star-compute`, tolération taint, volume reference en RO
- `STAR_GENOMEGENERATE` : 16 vCPU / 120 GB (génération one-shot d'index), volume reference en RW
- Endpoint S3 Scaleway configuré dans le bloc `aws.client`

**Scratch SBS haute IOPS (production)** : décommenter le bloc `volumeClaim` dans `withName:STAR_ALIGN` et supprimer `scratch = true` pour utiliser des PVC SBS dynamiques (`star-scratch`, 2 To, 25 687 IOPS) au lieu du workdir NFS.

---

## Contraintes connues

**STAR OOM** : 40 GB minimum stricts par job. En dessous, STAR échoue sans message clair. Les instances MEMORY3-X (8 GB/vCPU) sont le seul choix viable sur Scaleway pour tenir 4 jobs/nœud.

**Pas de Spot sur Kapsule** : Scaleway ne propose pas d'instances préemptibles. Le Cluster Autoscaler scale le pool `star-compute` à 0 entre les runs. Nextflow `-resume` gère les interruptions.

**NFS ClusterIP depuis kubelet** : Cilium sur Kapsule utilise des hooks eBPF cgroup-level qui interceptent les connexions ClusterIP depuis le namespace hôte. Les mounts NFS via ClusterIP depuis le kubelet sont supportés sans configuration supplémentaire.

**SBS StorageClass** : le provisioner CSI dans Kapsule est `bs.csi.scaleway.com`. La classe `scw-bssd` est provisionnée automatiquement par Kapsule et utilisée par le NFS server backing.

**Index STAR pré-généré** : après `make upload-reference`, pointer `star_index: "/data/reference/star_index/GRCh38_150bp"` dans `params.yaml` pour éviter de regénérer l'index (~4-6h) à chaque run.

---

## Structure du repo

```
terraform/
  main.tf           # Providers, kubeconfig, provider kubernetes
  cluster.tf        # VPC + Private Network + Kapsule (Cilium, k8s 1.35.3)
  node_pools.tf     # Pool orchestrator + pool star-compute (taint, autoscale)
  storage.tf        # Buckets S3 input/results
  kubernetes.tf     # NFS server, PVs/PVCs, RBAC, StorageClass, Secret, ConfigMap
  iam.tf            # Application IAM nextflow + API key + policy S3
  variables.tf      # Instance types, tailles stockage, max nœuds
  outputs.tf        # Buckets, ClusterIP NFS, quickstart
  terraform.tfvars.example  # Template credentials (ne pas committer terraform.tfvars)

nextflow/
  nextflow.config   # Profil scaleway_kapsule (executor k8s, ressources par process)
  params.yaml       # Paramètres par run (input, outdir, génome, read_length)

scripts/
  bootstrap-reference.sh  # Génération one-shot de l'index STAR GRCh38
  run-pipeline.sh         # Lancement nextflow run avec le profil scaleway_kapsule
```

---

## Teardown

```bash
make clean   # terraform destroy — supprime cluster, nœuds, PVCs, buckets S3
```

> Les buckets S3 sont détruits avec leur contenu (`force_destroy = true`). Sauvegarder les résultats avant `make clean`.
