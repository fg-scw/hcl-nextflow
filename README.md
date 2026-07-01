# nf-core/rnaseq sur Scaleway Kapsule

Pipeline bioinformatique **nf-core/rnaseq** (aligneur STAR) déployé sur **Scaleway Kapsule** (Kubernetes managé). Infrastructure complète provisionnée par Terraform : cluster, node pools, stockage NFS in-cluster, buckets S3, IAM.

**Charge cible** : 300-400 échantillons/run · 10 jobs STAR simultanés · 80 vCPU + 520 GB RAM en pic (POC) · 2,2 To FASTQ → 1,5 To BAM

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

### Node pools

| Pool | Instance | vCPU | RAM | Rôle | Autoscale |
|---|---|---|---|---|---|
| `orchestrator` | POP2-4C-16G | 4 | 16 GB | Nextflow head job | min=1, toujours actif |
| `star-compute` | POP2-HM-8C-64G | 8 | 64 GB | 1 job STAR par nœud | min=0, scale-to-zero, max=10 |

**Famille POP2 requise** pour le driver CSI File Storage (`filestorage.csi.scaleway.com`). La série POP2-HM (High Memory) offre le même ratio mémoire que les MEMORY3 (8 GB/vCPU). Packing POC : 1 job × (7 CPU demandés + 52 GB) par nœud de 8 vCPU — un cœur reste disponible pour la réserve Kubernetes. L'index GRCh38 (~32 GB) tient en RAM avec une marge pour l'OS et les I/O STAR. Pour augmenter le packing en production : `POP2-HM-16C-128G` (2 jobs/nœud) ou `POP2-HM-32C-256G` (4 jobs/nœud).

### Stockage

| Volume | Type | Capacité | Mode | Usage |
|---|---|---|---|---|
| `nf-workdir-pvc` | SFS (`sfs-standard`) | 2 To | ReadWriteMany | Nextflow workdir + SAM/BAM temporaires |
| `nf-reference-pvc` | SFS (`sfs-standard`) | 500 Go | ReadWriteMany | Index STAR GRCh38 (~32 Go) + GTF |
| `nf-kapsule-input` | S3 | illimité | — | FASTQ bruts (2,2 To par run NovaSeq S4) |
| `nf-kapsule-results` | S3 | illimité | — | BAM triés + count tables |
| `star-scratch` (optionnel) | SBS RWO dynamique | 2 To/job | ReadWriteOnce | Scratch haute IOPS en production |

Le stockage partagé utilise le **CSI driver SFS natif Kapsule** (`filestorage.csi.scaleway.com`), activé par le tag `scw-filestorage-csi` au niveau du cluster. Les PVCs sont provisionnées dynamiquement en `ReadWriteMany` — tous les pods task Nextflow montent le même volume simultanément sans infrastructure NFS intermédiaire.

**Performance SFS** : débit et IOPS scalent linéairement avec la taille provisionnée.

---

## Prérequis

- Terraform ≥ 1.5
- Scaleway CLI (`scw`) configuré
- AWS CLI (`aws`)
- `curl`
- `jq`
- `kubectl`
- Un compte Scaleway avec accès au projet cible

---

## Démarrage rapide

```bash
# 1. Credentials
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Remplir : scw_access_key, scw_secret_key, scw_project_id

# 2. Déployer l'infrastructure (~15-20 min)
#    make cluster s'exécute en 3 phases :
#    - Phase 0 : VPC + Private Network (~1 min)
#    - Phase 1 : cluster Scaleway + node pools + kubeconfig (~10-15 min)
#    - Attente stabilisation API K8s (60s)
#    - Phase 2 : namespace, RBAC, PVCs SFS, ConfigMap, Secret (~2 min)
make init
make cluster

# Alternative en une commande : déploiement + smoke test officiel nf-core
# make deploy-and-smoke

# 3. Configurer kubectl
make kubeconfig
kubectl get nodes

# 4. Vérifier le driver SFS CSI et les PVCs
kubectl get daemonset -n kube-system filestorage-csi-node   # doit être Running
kubectl get pvc -n bioinformatics                           # doit être Bound

# 5. Valider automatiquement S3 → Kapsule → nf-core/rnaseq → S3
make smoke-test

# 6. Générer l'index STAR GRCh38 pour les vrais runs (one-shot, ~4-6h)
make upload-reference

# 7. Uploader les vrais FASTQ dans S3
INPUT_BUCKET=$(terraform -chdir=terraform output -raw input_bucket_name)
aws --endpoint-url https://s3.fr-par.scw.cloud \
    s3 sync /chemin/reel/vers/fastq/ s3://$INPUT_BUCKET/

# 8. Adapter les paramètres du run
vi nextflow/params.yaml   # input, outdir, star_index si pré-généré

# 9. Lancer le pipeline
make run-pipeline

# 10. Surveiller le scaling
make watch-nodes   # nœuds compute qui scale up/down
make watch-pods    # pods du namespace bioinformatics
```

---

## Commandes

```bash
make init              # terraform init
make cluster           # Déployer toute l'infrastructure
make deploy-and-smoke  # Initialiser, déployer et exécuter le smoke test
make kubeconfig        # Installer le kubeconfig → ~/.kube/config-nf-kapsule
make status            # État nœuds + PVCs + pods
make smoke-test        # Dataset officiel nf-core, upload et exécution automatiques
make upload-reference  # Générer l'index STAR dans le volume reference
make run-pipeline      # Lancer nf-core/rnaseq via Nextflow executor k8s
make watch-nodes       # Surveiller les nœuds compute (autoscaling)
make watch-pods        # Pods du namespace bioinformatics en temps réel
make scale-check       # État du Cluster Autoscaler
make logs-autoscaler   # Logs du Cluster Autoscaler
make outputs           # Afficher les outputs Terraform (buckets, IPs, etc.)
make clean             # terraform destroy (⚠ supprime cluster et données)
```

`make smoke-test` et `make run-pipeline` créent un Job head dans le pool
`orchestrator` avec l'image `nextflow/nextflow:25.10.4`. Java et Nextflow ne
sont donc pas requis sur le poste local.

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
- `STAR_ALIGN` : 7 CPU / 52 GB sur un nœud 8 vCPU, `nodeSelector` pool `star-compute`, tolération taint, volume reference en RO
- `STAR_GENOMEGENERATE` : 7 CPU / 56 GB (génération one-shot d'index), volume reference en RW
- Endpoint S3 Scaleway configuré dans le bloc `aws.client`

**Scratch SBS haute IOPS (production)** : décommenter le bloc `volumeClaim` dans `withName:STAR_ALIGN` et supprimer `scratch = true` pour utiliser des PVC SBS dynamiques (`star-scratch`, 2 To, 25 687 IOPS) au lieu du workdir SFS.

---

## Contraintes connues

**Déploiement en trois phases** : `make cluster` enchaîne automatiquement trois `terraform apply` successifs, séparés par une attente de 60s.
- **Phase 0** : VPC + Private Network (créés et propagés dans l'API Scaleway avant la suite)
- **Phase 1** : cluster Kapsule + node pools, puis installation du kubeconfig hors du graphe Terraform
- **Attente 60s** : laisse le control plane K8s du nouveau cluster devenir joignable avant que le provider `kubernetes` ne s'y connecte
- **Phase 2** : namespace, RBAC, PVCs SFS, ConfigMap, Secret Kubernetes

Ne pas interrompre entre les phases. Le cluster conserve `delete_additional_resources = false` afin qu'un remplacement Kapsule ne supprime pas le Private Network géré par Terraform. Si un ancien déploiement a laissé un ID de PN orphelin dans le state, relancer `make cluster` : le refresh de la Phase 0 détectera sa disparition et le recréera avant la Phase 1.

Le provider `kubernetes` (`terraform/main.tf`) lit `~/.kube/config-nf-kapsule`, installé par la CLI Scaleway entre les phases 1 et 2. Le fichier n'est pas une ressource Terraform : Terraform ne peut donc pas le supprimer temporairement pendant un remplacement et faire retomber le provider sur `localhost:80` (`connection refused`).

**STAR OOM** : 40 GB minimum stricts par job (index GRCh38 chargé intégralement en RAM). En dessous, STAR échoue sans message d'erreur explicite. Le POC utilise 52 GB/job sur `POP2-HM-8C-64G` (1 job/nœud). Pour augmenter le packing en production : `POP2-HM-32C-256G` (4 jobs/nœud).

**Pas de Spot sur Kapsule** : Scaleway ne propose pas d'instances préemptibles. Le Cluster Autoscaler scale le pool `star-compute` à 0 entre les runs. Nextflow `-resume` gère les interruptions.

**SFS CSI driver** : activé par le tag `scw-filestorage-csi` au niveau du cluster. Requiert la famille POP2 — BASIC3/MEMORY3 non compatibles. Vérifier après déploiement : `kubectl get daemonset -n kube-system filestorage-csi-node`.

**Index STAR pré-généré** : après `make upload-reference`, pointer `star_index: "/data/reference/star_index/GRCh38_150bp"` dans `params.yaml` pour éviter de regénérer l'index (~4-6h) à chaque run.

---

## Structure du repo

```
terraform/
  main.tf           # Providers, kubeconfig, provider kubernetes
  cluster.tf        # VPC + Private Network + Kapsule (Cilium, k8s 1.35.3)
  node_pools.tf     # Pool orchestrator + pool star-compute (taint, autoscale)
  storage.tf        # Buckets S3 input/results
  kubernetes.tf     # PVCs SFS (sfs-standard, RWX), RBAC, StorageClass, Secret, ConfigMap
  iam.tf            # Application IAM nextflow + API key + policy S3
  variables.tf      # Instance types, tailles stockage, max nœuds
  outputs.tf        # Buckets, PVCs SFS, quickstart
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
