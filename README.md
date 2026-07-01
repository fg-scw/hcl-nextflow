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

# 6. Générer l'index STAR GRCh38 pour les vrais runs (one-shot, ~1h sur MEMORY3-X8C-64G)
#    L'index (~28 Go) est conservé dans nf-reference-pvc — ne pas relancer entre les runs.
make upload-reference

# 7. Uploader les FASTQ réels dans S3 (voir section "Accès aux données source")
#    ⚠️  Les FASTQs du smoke test (SRR6357070) sont dans s3://<input-bucket>/smoke/
#        et ne sont PAS sur ta machine (supprimés localement après upload par smoke-test.sh)
ACCESS_KEY=$(kubectl get secret pipeline-s3-credentials -n bioinformatics \
  -o jsonpath='{.data.access-key}' | base64 -d)
SECRET_KEY=$(kubectl get secret pipeline-s3-credentials -n bioinformatics \
  -o jsonpath='{.data.secret-key}' | base64 -d)
RUN_ID="run-$(date +%Y%m%d)"
AWS_ACCESS_KEY_ID="$ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$SECRET_KEY" \
aws --endpoint-url https://s3.fr-par.scw.cloud \
    s3 sync /nas/fastq/run-DATE/ s3://nf-kapsule-input/$RUN_ID/ --no-progress

# 8. Créer la samplesheet et l'uploader (voir section "Accès aux données source")
# puis adapter nextflow/params.yaml :
#   input:  "s3://nf-kapsule-input/run-DATE/samplesheet.csv"
#   outdir: "s3://nf-kapsule-results/run-DATE"
#   (star_index déjà activé après make upload-reference)
vi nextflow/params.yaml

# 9. Lancer le pipeline
make run-pipeline

# 10. Surveiller le scaling
make watch-nodes   # nœuds compute qui scale up/down
make watch-pods    # pods du namespace bioinformatics
```

---

## Accès aux données source et upload FASTQ

Les FASTQ proviennent du séquenceur NovaSeq (on-premise) et doivent être uploadés dans le bucket S3 input avant chaque run. Trois scénarios selon l'interconnexion disponible.

### Credentials S3 pour l'upload

Les credentials IAM pipeline sont stockés dans le secret Kubernetes et peuvent être extraits directement :

```bash
ACCESS_KEY=$(kubectl get secret pipeline-s3-credentials -n bioinformatics \
  -o jsonpath='{.data.access-key}' | base64 -d)
SECRET_KEY=$(kubectl get secret pipeline-s3-credentials -n bioinformatics \
  -o jsonpath='{.data.secret-key}' | base64 -d)
```

### Scénario A — Copie directe NAS → S3 Scaleway (recommandé POC)

Le NAS pousse directement vers le bucket S3 via Internet. Aucune interconnexion réseau supplémentaire requise.

```bash
RUN_ID="run-$(date +%Y%m%d)"

# Depuis le NAS ou un serveur avec accès au NAS
AWS_ACCESS_KEY_ID="$ACCESS_KEY" \
AWS_SECRET_ACCESS_KEY="$SECRET_KEY" \
aws --endpoint-url https://s3.fr-par.scw.cloud \
    s3 sync /nas/fastq/run-DATE/ s3://nf-kapsule-input/$RUN_ID/ \
    --no-progress \
    --exclude "*.tmp" \
    --include "*.fastq.gz"
```

### Scénario B — Scaleway Interlink (Direct Connect, production)

Scaleway Interlink crée une connexion privée dédiée entre ton datacenter on-premise et le réseau Scaleway via BGP. Le NAS devient accessible depuis les pods Kapsule sur le Private Network (172.16.8.0/22) sans passer par Internet.

**Architecture** :
```
NAS on-premise ──BGP──► Routeur Interlink ──► Private Network 172.16.8.0/22
                                                       │
                                              Pods Kapsule (nf-workdir-pvc monté)
```

**Prérequis** :
- Port Interlink commandé chez Scaleway (tarification dédiée)
- BGP configuré entre ton routeur et le routeur Scaleway
- Route annoncée vers le sous-réseau NAS depuis le Private Network Kapsule

**Impact sur le pipeline** : avec l'Interlink, les FASTQ restent sur le NAS. La samplesheet pointe vers des chemins NFS montés plutôt que des URLs S3. Nécessite de modifier `nextflow.config` pour monter le NAS comme volume supplémentaire dans les pods task.

### Scénario C — VPN site-à-site

VPN IPsec ou WireGuard entre le réseau on-premise et le Private Network Kapsule. Le NAS est accessible depuis les pods via une IP privée.

Ajouter une VM VPN dans le Private Network Kapsule (172.16.8.0/22) qui termine le tunnel VPN et route vers le NAS. Moins de débit que l'Interlink mais sans engagement de port dédié.

---

### Créer la samplesheet

Une fois les FASTQ uploadés en S3 (Scénario A), générer la samplesheet depuis le listing du bucket :

```bash
RUN_ID="run-$(date +%Y%m%d)"

# Convention de nommage Illumina DRAGEN/bcl-convert : SAMPLE_S1_L001_R1_001.fastq.gz
echo "sample,fastq_1,fastq_2,strandedness" > samplesheet.csv

AWS_ACCESS_KEY_ID="$ACCESS_KEY" \
AWS_SECRET_ACCESS_KEY="$SECRET_KEY" \
aws --endpoint-url https://s3.fr-par.scw.cloud \
    s3 ls s3://nf-kapsule-input/$RUN_ID/ --recursive \
  | grep "_R1_" \
  | awk '{print $4}' \
  | while read r1; do
      r2="${r1/_R1_/_R2_}"
      sample=$(basename "$r1" | sed 's/_S[0-9]*_L[0-9]*_R1_001\.fastq\.gz//')
      echo "$sample,s3://nf-kapsule-input/$r1,s3://nf-kapsule-input/$r2,auto"
    done >> samplesheet.csv

# Upload de la samplesheet dans le même préfixe
AWS_ACCESS_KEY_ID="$ACCESS_KEY" \
AWS_SECRET_ACCESS_KEY="$SECRET_KEY" \
aws --endpoint-url https://s3.fr-par.scw.cloud \
    s3 cp samplesheet.csv s3://nf-kapsule-input/$RUN_ID/samplesheet.csv
```

Adapter le pattern `sed` si la convention de nommage diffère (NextSeq, custom bcl2fastq, etc.).

---

## Validation bout-en-bout (résultats observés)

Cette section documente le résultat de la validation complète du POC sur Scaleway Kapsule.

### Infrastructure déployée

```
Cluster     : nf-kapsule (Kapsule, Cilium, k8s 1.35.3, fr-par-1)
Orchestrator: BASIC3-X4C-16G  (4 vCPU / 16 GB, min=1)
Compute     : MEMORY3-X8C-64G (8 vCPU / 64 GB, min=0, max=10)
Stockage    : nf-workdir-pvc 2 To SFS + nf-reference-pvc 500 Go SFS
S3          : nf-kapsule-input + nf-kapsule-results
Déploiement : ~15 min (make cluster, 3 phases)
```

### Smoke test — `make smoke-test`

Dataset officiel nf-core : GSE110004 / SRR6357070 (Illumina paired-end 150 bp, 2× ~2 MB).

```
Pipeline    : nf-core/rnaseq v3.14.0, profil scaleway_smoke (2 CPU / 8 GB)
Durée       : 6 min 59 s
Tâches      : 60 succeeded
Image NF    : nextflow/nextflow:25.10.4
Résultat    : s3://nf-kapsule-results/smoke-20260701-102004/multiqc/star_salmon/multiqc_report.html ✓
```

Note : le warning `1/1 samples failed strandedness check` est attendu pour ce dataset test, pas un problème d'infrastructure.

### Génération index STAR — `make upload-reference`

Index GRCh38 Ensembl 110, sjdbOverhang=149 (read_length=150 bp), 7 threads sur MEMORY3-X8C-64G.

```
Démarrage   : 08:35:11
Fin         : 09:40:07
Durée réelle: 1h 05min (vs 4-6h estimés — MEMORY3-X8C-64G est plus rapide)
Taille index: ~28 Go (Genome 3 Go + SA 23,6 Go + SAindex 1,5 Go)
Emplacement : nf-reference-pvc:/data/reference/star_index/GRCh38_150bp/
```

L'index est permanent sur le PVC SFS — il n'est pas à regénérer entre les runs sauf changement de génome ou de longueur de lecture.

### Run production — `make run-pipeline` (profil `scaleway_kapsule`)

Le profil `scaleway_kapsule` (à distinguer du profil `scaleway_smoke` utilisé par `make smoke-test`) utilise les ressources réelles : 7 CPU / 52 GB pour STAR sur le pool `star-compute`. Deux bugs ont été identifiés et corrigés lors de la première exécution :

| Bug | Symptôme | Correction |
|---|---|---|
| `nf-reference-pvc` absent du pod head | `file or directory does not exist` à la validation Nextflow | Ajout du montage dans `launch-nextflow-job.sh` |
| `nf-reference-pvc` absent des pods task | `FileNotFoundError: genes.gtf` dans GTF_FILTER | Directive `k8s.pod` globale dans `nextflow.config` |
| TRIMGALORE/FASTQC → 7/4 CPU | Pods non-schedulables sur orchestrateur 4 vCPU | Réduits à 2 CPU / 8 GB dans `nextflow.config` |
| `MAKE_TRANSCRIPTS_FASTA` / `SALMON_INDEX` → 8 CPU (bloqués) | Labels nf-core `withLabel 'process_high'` (12 CPU) cappés par `max_cpus=8` de `params.yaml` qui écrase `nextflow.config` | (1) `withName: '.*' { cpus=2 }` en premier dans `process {}` — seul `withName` surcharge les `withLabel` ; (2) `max_cpus`/`max_memory` retirés de `params.yaml` |

### Configuration pour les vrais runs

Après `make upload-reference`, `nextflow/params.yaml` est configuré en Option B (index pré-généré) :

```yaml
star_index: "/data/reference/star_index/GRCh38_150bp"
gtf:        "/data/reference/gtf/genes.gtf"
fasta:      "/data/reference/fasta/genome.fa"
```

Avant chaque run réel, adapter uniquement :

```yaml
input:  "s3://nf-kapsule-input/run-DATE/samplesheet.csv"
outdir: "s3://nf-kapsule-results/run-DATE"
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

**SFS CSI driver** : activé par le tag `scw-filestorage-csi` au niveau du cluster. La documentation Scaleway indique la famille POP2, mais BASIC3 et MEMORY3 fonctionnent également en `fr-par-1` (validé en production). Vérifier après déploiement : `kubectl get daemonset -n kube-system filestorage-csi-node`.

**`nf-reference-pvc` : deux points de montage requis** :

1. **Pod head Nextflow** (`scripts/launch-nextflow-job.sh`) : Nextflow valide l'existence des chemins `star_index`, `gtf`, `fasta` au démarrage depuis le pod head. Sans le montage de `nf-reference-pvc` à `/data/reference`, la validation échoue immédiatement avec `file or directory does not exist`.

2. **Tous les pods task** (`nextflow/nextflow.config`, bloc `k8s {}`) : les tâches `PREPARE_GENOME` (GTF_FILTER, GETCHROMSIZES, GTF2BED, MAKE_TRANSCRIPTS_FASTA, SALMON_INDEX) accèdent aux fichiers de référence via symlink depuis le workdir NFS. Si le PVC n'est pas monté sur le pod task, le symlink existe mais sa cible (`/data/reference/...`) est inaccessible → `FileNotFoundError: No such file or directory`. La directive `k8s.pod` dans `nextflow.config` monte le PVC sur **tous** les pods task ; Nextflow merge cette directive avec les directives `pod` des process individuels (STAR_ALIGN, etc.).

**Ressources task vs capacité orchestrateur** : `TRIMGALORE` et `FASTQC` s'exécutent sur le pool orchestrateur (pas de taint, pas de tolération star-compute). Le nœud `BASIC3-X4C-16G` dispose de 4 vCPU / 16 GB. Avec le pod head qui consomme 500m CPU / 1Gi et les pods système (~500m CPU), il reste environ **2-3 vCPU / 13 GB** disponibles pour les tâches. Configurer `cpus > 3` pour ces tâches bloque le scheduling définitivement — même l'autoscaler ne peut pas aider car aucun nœud orchestrateur ne peut accueillir un pod de 7 CPU. Valeurs corrigées : FASTQC et TRIMGALORE à 2 CPU / 8 GB (≈ 1 tâche par nœud orchestrateur).

**Params invalides en v3.14.0** : `--read_length` et `--strandedness` ne sont plus des paramètres top-level valides dans nf-core/rnaseq v3.14.0 (déplacés au niveau de la samplesheet, colonne `strandedness`). Les inclure dans `params.yaml` génère des WARNs non-bloquants mais pollue les logs. Retirés de `params.yaml` — la longueur de lecture est implicite dans l'index STAR pré-généré (`sjdbOverhang=149` pour 150 bp).

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
