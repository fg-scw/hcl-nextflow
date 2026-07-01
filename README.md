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

# 7. Préparer les données de démonstration dans S3 (SRR1039508, human GRCh38-compatible)
#    ⚠️  Les FASTQs du smoke test (SRR6357070) sont de la levure (taxid|4932) — ils ne s'alignent pas sur GRCh38.
#    make prepare-demo télécharge SRR1039508 (Himes et al. 2014, human airway, ~5 min) et crée la samplesheet.
make prepare-demo

# 8. Pour les vrais FASTQs NovaSeq, uploader à la place (voir section "Accès aux données source")
# et adapter nextflow/params.yaml :
#   outdir: "s3://nf-kapsule-results/run-DATE"
#   star_index: commenté sur un nouveau cluster (nf-core génère l'index au 1er run)
vi nextflow/params.yaml   # (optionnel : adapter outdir)

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

Cette section documente les résultats **réels et mesurés** de la validation complète du POC sur Scaleway Kapsule, réalisée le 2026-07-01.

---

### Étape 1 — Déploiement de l'infrastructure : `make cluster`

```
$ make cluster
```

Terraform déploie en 3 phases automatiques (~15 min) :

| Phase | Ressources créées | Durée |
|---|---|---|
| Phase 0 | VPC + Private Network (`nf-vpc`) | ~2 min |
| Phase 1 | Cluster Kapsule + pools orchestrateur/star-compute + kubeconfig | ~8 min |
| Attente 60s | Control plane K8s joignable | — |
| Phase 2 | Namespace `bioinformatics`, RBAC, PVCs SFS, ConfigMap nextflow.config, Secret S3 | ~3 min |

**Infrastructure provisionnée :**

```
Cluster      : nf-kapsule (Kapsule, Cilium CNI, k8s 1.35.3, fr-par-1)
Orchestrateur: BASIC3-X4C-16G  — 4 vCPU / 16 GB, min=1, toujours actif
Compute      : POP2-HM-8C-64G  — 8 vCPU / 64 GB, min=0, max=10 (scale-to-zero)
               Note : MEMORY3-X8C-64G indisponible en fr-par-1 le 2026-07-01
Workdir SFS  : nf-workdir-pvc  — 2 To RWX (filestorage.csi.scaleway.com)
Reference SFS: nf-reference-pvc — 500 Go RWX
S3 input     : nf-kapsule-input
S3 results   : nf-kapsule-results
```

**Vérification :**

```bash
$ make status
NAME                                             STATUS   ROLES    AGE
scw-nf-kapsule-kapsule-orchestrator-b2ea2ad2a2   Ready    <none>   15m

$ kubectl get pvc -n bioinformatics
NAME                STATUS   CAPACITY   ACCESS MODES
nf-workdir-pvc      Bound    2000Gi     RWX
nf-reference-pvc    Bound    500Gi      RWX
```

---

### Étape 2 — Génération de l'index STAR GRCh38 : `make upload-reference`

```
$ make upload-reference
```

Le script `bootstrap-reference.sh` lance un Job K8s sur le nœud `star-compute` qui :
1. Télécharge `Homo_sapiens.GRCh38.dna.primary_assembly.fa.gz` + GTF Ensembl 110
2. Génère l'index STAR avec 7 threads et 56 GB RAM

> **Note** : cet index bootstrap (STAR 2.7.10b) n'est **pas compatible** avec le container `STAR_ALIGN_IGENOMES` de nf-core (STAR 2.6.1d). Le vrai index utilisé en production est généré automatiquement par `STAR_GENOMEGENERATE_IGENOMES` lors du premier `make run-pipeline` (voir ci-dessous).

```
Durée réelle : ~1h 05 min
Taille index : ~28 Go (Genome 3 Go + SA 23,6 Go + SAindex 1,5 Go)
Emplacement  : nf-reference-pvc:/data/reference/star_index/GRCh38_150bp/
Génome       : genome.fa → /data/reference/fasta/genome.fa
GTF          : genes.gtf → /data/reference/gtf/genes.gtf
```

Les fichiers génome et GTF sont permanents sur le PVC SFS. L'index STAR de nf-core est quant à lui dans le workdir SFS (géré par Nextflow).

---

### Étape 2b — Préparer les données de démonstration : `make prepare-demo`

```
$ make prepare-demo
```

Le script `prepare-demo.sh` télécharge les 50 000 premières paires de reads de **SRR1039508** depuis ENA (Himes et al. 2014 — human airway smooth muscle cells, HiSeq 2000, TruSeq RNA non-stranded, 63 bp PE) et les uploade dans le bucket S3 input avec une samplesheet prête à l'emploi.

> **Pourquoi SRR1039508 ?** Les FASTQs du smoke test (`testdata/GSE110004/SRR6357070`) ont `kraken:taxid|4932` dans leurs headers : ce sont des reads de *Saccharomyces cerevisiae* (levure synthétique), conçus pour le profil `test` nf-core avec le génome R64-1-1. Ils ne s'alignent **pas** sur GRCh38. SRR1039508 est un dataset humain largement utilisé pour valider les pipelines RNA-seq.

```
Durée réelle  : ~5 min (download ENA + upload S3)
Sortie S3     : s3://<input-bucket>/smoke/SRR1039508_{1,2}.fastq.gz
Samplesheet   : s3://<input-bucket>/samplesheet.csv
Strandedness  : unstranded
```

Pour les vrais FASTQs NovaSeq, cette étape est remplacée par l'upload direct depuis le NAS (voir section "Accès aux données source").

---

### Étape 3 — Run pipeline complet : `make run-pipeline`

```
$ make run-pipeline
```

**Prérequis :** `make prepare-demo` doit avoir été exécuté (samplesheet et FASTQs SRR1039508 dans S3), ou les FASTQs NovaSeq réels uploadés à la place.

**Dataset de validation :** SRR1039508 (Himes et al. 2014 — human airway smooth muscle cells, HiSeq 2000, TruSeq RNA non-stranded, 50 000 reads PE ~63 bp, GRCh38).

#### Résultats étape par étape

**Pod head Nextflow** créé dans le pool `orchestrator` :

```
Job     : nextflow-run-20260701-184730
Image   : nextflow/nextflow:25.10.4
Profile : scaleway_kapsule
WorkDir : /data/workdir (nf-workdir-pvc, SFS RWX)
```

**Séquence d'exécution observée :**

| Heure | Étape | Résultat | Node |
|---|---|---|---|
| 18:47 | Job head Nextflow démarré | Pod Running | orchestrateur |
| 18:49 | `PREPARE_GENOME:GTF_FILTER` | ✔ ~1 min | orchestrateur |
| 18:49 | `PREPARE_GENOME:CUSTOM_GETCHROMSIZES` | ✔ | orchestrateur |
| 18:49 | `UMITOOLS_TRIMGALORE:FASTQC` | ✔ | orchestrateur |
| 18:49 | `UMITOOLS_TRIMGALORE:TRIMGALORE` | ✔ | orchestrateur |
| 18:50 | `PREPARE_GENOME:GTF2BED` | ✔ | orchestrateur |
| 18:50 | `PREPARE_GENOME:MAKE_TRANSCRIPTS_FASTA` | ✔ | orchestrateur |
| 18:51 | `STAR_GENOMEGENERATE_IGENOMES` | ✔ (nœud star-compute provisionné) | star-compute |
| 18:51 | **STAR_ALIGN_IGENOMES** | Pod Running — RAM monte à **35 GB** (index GRCh38 chargé) | star-compute |
| 18:55 | `STAR_ALIGN_IGENOMES` | ✔ **— BAM produit avec reads alignés** | star-compute |
| 18:56 | `SAMTOOLS_SORT` → `SAMTOOLS_INDEX` | ✔ | star-compute |
| 18:56 | `SALMON_QUANT` (alignment-based) | ✔ | star-compute |
| 18:57 | `PICARD_MARKDUPLICATES` | ✔ | orchestrateur |
| 18:57 | `RSEQC_BAMSTAT`, `RSEQC_INNERDISTANCE`, `RSEQC_INFEREXPERIMENT` | ✔ ×5 | orchestrateur |
| 18:57 | `RSEQC_JUNCTIONANNOTATION`, `RSEQC_JUNCTIONSATURATION` | ✔ | orchestrateur |
| 18:57 | `RSEQC_READDISTRIBUTION`, `RSEQC_READDUPLICATION` | ✔ | orchestrateur |
| 18:57 | `DUPRADAR`, `QUALIMAP_RNASEQ` | ✔ | orchestrateur |
| 18:58 | `FEATURECOUNTS`, `STRINGTIE` | ✔ | orchestrateur |
| 18:58 | `BEDTOOLS_GENOMECOV` → `BEDGRAPHTOBIGWIG` ×2 | ✔ | orchestrateur |
| 18:59 | `QUANTIFY_STAR_SALMON:TXIMPORT` | ✔ | orchestrateur |
| 18:59 | `DESEQ2_QC_STAR_SALMON` | ✔ | orchestrateur |
| 19:02 | `MULTIQC` | ✔ | orchestrateur |
| **19:03** | **Pipeline terminé** | **44 tâches succeeded** | — |

**Résumé final Nextflow :**

```
-[nf-core/rnaseq] Pipeline completed successfully -
Completed at : 01-Jul-2026 17:03:27
Duration     : 15m 37s
CPU hours    : 1.1
Succeeded    : 44
```

**Autoscaling observé :**

```bash
$ kubectl get nodes
NAME                                             STATUS
scw-nf-kapsule-kapsule-orchestrator-b2ea2ad2a2   Ready   # orchestrateur permanent
scw-nf-kapsule-kapsule-star-compute-32975f52dc   Ready   # provisionné par autoscaler pour STAR
```

Le nœud `star-compute` (POP2-HM-8C-64G) a été provisionné automatiquement au moment de STAR_ALIGN_IGENOMES et libéré après la fin de l'alignement.

**Consommation RAM STAR observée (kubectl top nodes) :**

```
t+0min  :  1 159 Mi   (1%)   — chargement de l'index
t+2min  : 24 800 Mi  (40%)   — GRCh38 genome loading
t+4min  : 35 324 Mi  (57%)   — alignment en cours (7 threads actifs)
t+5min  :    474 Mi   (1%)   — pod terminé, nœud libéré
```

**Sorties S3 :**

```
$ aws s3 ls s3://nf-kapsule-results/run-20260701-184730/ --recursive

star_salmon/SRR1039508.markdup.sorted.bam           6.2 MB
star_salmon/SRR1039508.markdup.sorted.bam.bai       1.7 MB
star_salmon/SRR1039508/quant.sf                     transcript-level counts (Salmon)
star_salmon/SRR1039508/aux_info/meta_info.json      mapping stats
star_salmon/salmon.merged.gene_counts.tsv           gene count matrix
star_salmon/salmon.merged.gene_tpm.tsv              TPM matrix
fastqc/SRR1039508_1_fastqc.html                     FastQC R1
fastqc/SRR1039508_2_fastqc.html                     FastQC R2
multiqc/star_salmon/multiqc_report.html   ← rapport QC agrégé (1,4 MB) ✓
```

---

### Bugs identifiés et corrigés (session de validation complète)

Le pipeline POC nécessite plusieurs ajustements par rapport à un déploiement Nextflow k8s générique. Voici le journal complet des 11 problèmes rencontrés et résolus :

| # | Composant | Symptôme | Cause racine | Correction |
|---|---|---|---|---|
| 1 | Pod head Nextflow | `file or directory does not exist` au démarrage | `nf-reference-pvc` non monté dans le pod head → Nextflow ne peut pas valider les chemins `fasta`/`gtf` | Montage ajouté dans `launch-nextflow-job.sh` (volumes + volumeMounts) |
| 2 | `PREPARE_GENOME:GTF_FILTER` | `FileNotFoundError: genes.gtf` | `nf-reference-pvc` absent des pods task (seul le pod head le montait) | Directive `k8s.pod = [[volumeClaim: 'nf-reference-pvc', ...]]` dans `nextflow.config` — monte le PVC sur **tous** les pods task |
| 3 | `TRIMGALORE` / `FASTQC` | Pods en `Pending` indéfiniment | Demandaient 7 ou 4 CPU → non-schedulables sur orchestrateur 4 vCPU | `withName: '.*TRIM.*\|.*FASTQC.*' { cpus=2, memory='8.GB' }` |
| 4 | `MAKE_TRANSCRIPTS_FASTA` / `SALMON_INDEX` | Pods `Pending` (8 CPU demandés) | Labels nf-core `withLabel 'process_high'` (12 CPU) cappés par `max_cpus=8` dans `params.yaml` — mais `params.yaml` a priorité sur `nextflow.config` et écrase les `withName` | (a) `withName: '.*' { cpus=2 }` placé **en premier** dans `process {}` (les `withName` spécifiques ci-dessous l'écrasent) ; (b) `max_cpus`/`max_memory` retirés de `params.yaml` |
| 5 | `SALMON_INDEX` | OOM kill (exit 137) | pufferfish charge `gentrome.fa` (transcriptome + génome GRCh38 décoy, ~3,3 Go) entièrement en RAM = 30-40 GB requis. Pool orchestrateur (16 GB) insuffisant | `withName: '.*SALMON_INDEX.*'` routé sur `star-compute` (64 GB), 32 GB alloués, nodeSelector + toleration `workload=star-compute:NoSchedule` |
| 6 | `FASTQ_SUBSAMPLE_FQ_SALMON:SALMON_QUANT` | OOM kill (exit 137) puis exit 1 (0 fragments) | (a) Détection strandedness (`strandedness=auto`) charge l'index Salmon complet même avec `--skipQuant` ; (b) 50K reads test → trop peu de fragments assignés | `withName: '.*SALMON_QUANT.*'` sur `star-compute` avec 24 GB ; samplesheet modifié : `strandedness=unstranded` → sous-workflow de détection éliminé |
| 7 | `STAR_ALIGN_IGENOMES` | exit 102 (incompatibilité version STAR) | `star_index` dans `params.yaml` pointait vers un index construit par `bootstrap-reference.sh` avec STAR 2.7.10b. Le container nf-core `STAR_ALIGN_IGENOMES` utilise STAR 2.6.1d, incompatible | `star_index` désactivé dans `params.yaml` → nf-core génère l'index via `STAR_GENOMEGENERATE_IGENOMES` (même container STAR 2.6.1d, index compatible) |
| 8 | `STAR_ALIGN_IGENOMES` | exit 0 mais 0 reads alignés, `genomeFileSizes 0` dans Log.out | Double montage `/data/reference` : `k8s.pod` global **plus** `volumeClaim` dans `withName:STAR_ALIGN` → K8s rejette le pod (422 Unprocessable Entity, mountPath dupliqué) → STAR démarre avec un `genomeDir` vide | Suppression des entrées `volumeClaim: nf-reference-pvc` dans `withName:STAR_ALIGN` et `withName:STAR_GENOMEGENERATE` (le montage global suffit) |
| 9 | Nextflow `-resume` | SALMON_QUANT reçoit toujours 0 fragments après correction du bug #8 | STAR avait produit un BAM vide (exit 0), Nextflow l'avait mis en cache. `-resume` réutilisait silencieusement ce résultat corrompu. Impossible d'invalider une seule entrée du cache SQLite Nextflow sans accès au DB | `launch-nextflow-job.sh` modifié : `-resume` **désactivé par défaut** (opt-in via `NXF_RESUME=1`). Run propre sans cache → STAR régénère un BAM correct |
| 10 | Autoscaler `star-compute` | Nœuds non provisionnés | `MEMORY3-X8C-64G` indisponible en `fr-par-1` le 2026-07-01 | `terraform.tfvars` : `compute_node_type = "POP2-HM-8C-64G"` (même ratio RAM/vCPU 8 GB/vCPU, disponible en fr-par-1) |
| 11 | `STAR_ALIGN_IGENOMES` | 100% reads "too short" (0 alignements) | Les FASTQs nf-core (`testdata/GSE110004/SRR6357070_*.fastq.gz`) contiennent `kraken:taxid\|4932` dans les headers = *Saccharomyces cerevisiae* (levure). Ils sont conçus pour le profil `test` nf-core avec le génome R64-1-1, pas pour GRCh38 | Remplacement par `SRR1039508` (Himes et al. 2014, human airway smooth muscle cells, HiSeq 2000, TruSeq RNA non-stranded) — téléchargé depuis ENA, 50K reads, aligne correctement sur GRCh38 |

---

### Configuration pour les vrais runs NovaSeq

Avant chaque run réel, adapter `nextflow/params.yaml` :

```yaml
# Samplesheet CSV au format nf-core (un échantillon par ligne)
# sample,fastq_1,fastq_2,strandedness
input:  "s3://nf-kapsule-input/run-DATE/samplesheet.csv"
outdir: "s3://nf-kapsule-results/run-DATE"

# Génome de référence (fichiers sur nf-reference-pvc)
fasta: "/data/reference/fasta/genome.fa"
gtf:   "/data/reference/gtf/genes.gtf"

# Index STAR nf-core-built (STAR 2.6.1d, compatible STAR_ALIGN_IGENOMES)
# Généré automatiquement au premier run, permanent dans le workdir SFS
star_index: "/data/workdir/e6/f008e9f80442ab81aab5e09dbdf4a7/star"
```

Lancer le pipeline :

```bash
make run-pipeline            # Lancement normal (sans -resume — propre)
NXF_RESUME=1 make run-pipeline  # Reprendre après interruption (si outputs précédents valides)
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
make prepare-demo      # Télécharger SRR1039508 (human, GRCh38) et uploader dans S3
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

**Index STAR et nouveau cluster** : sur un **nouveau cluster**, laisser `star_index` commenté dans `params.yaml`. nf-core lancera `STAR_GENOMEGENERATE_IGENOMES` (STAR 2.6.1d — même container que `STAR_ALIGN_IGENOMES`) et placera l'index dans le workdir SFS. Après le premier run, retrouver le chemin de l'index généré (`kubectl exec` dans un pod ou `aws s3 ls`) et le renseigner dans `params.yaml` pour les runs suivants. ⚠️ Ne pas utiliser l'index bootstrap de `make upload-reference` (STAR 2.7.10b → incompatible → exit 102 au chargement).

---

## Choix du dimensionnement des nœuds

Cette section s'adresse aux bioinformaticiens qui dimensionnent une infrastructure pour traiter des données NovaSeq. Elle n'est pas spécifique à Scaleway.

### La RAM prime sur le CPU

Pour les outils d'alignement standard, la RAM est le facteur limitant — pas le CPU :

| Outil | RAM requise | CPU utile | Contrainte réelle |
|---|---|---|---|
| STAR (GRCh38) | **32 GB** (index chargé intégralement en RAM) | 8-16 threads max | **RAM** |
| BWA-MEM2 (hg38) | **60 GB** (index hg38) | 16-32 threads | **RAM** |
| HISAT2 (GRCh38) | ~8 GB | 8-16 threads | **RAM** |
| Salmon quant | 2-4 GB | 4-8 threads | ni l'un ni l'autre |
| GATK HaplotypeCaller | 8-16 GB | 4-8 threads, scatter/gather | **CPU** |
| De novo assembly | 500 GB+ | scalable | **RAM critique** |
| FastQC / Trimming | <4 GB | 4 threads | **I/O** |

STAR échoue silencieusement (OOM kill, exit 137) si la RAM disponible est inférieure à 40 GB pour GRCh38 — sans message d'erreur explicite dans les logs. Voir la section "Contraintes connues".

### L'ennemi oublié : l'I/O disque

Un run NovaSeq S4 génère 2,2 To de FASTQ. Avec 10 jobs STAR simultanés lisant chacun ~20 GB, le débit du stockage partagé devient le bottleneck avant la RAM ou le CPU. Sur un SFS partagé (NFS), contention possible si le débit ne scale pas avec le nombre de jobs.

Points de vigilance :
- **SFS Scaleway** : débit et IOPS proportionnels à la taille provisionnée — sur-provisionner légèrement le workdir évite les goulots d'étranglement
- **Scratch local** : pour des I/O maximales, utiliser des PVC SBS (`star-scratch`) plutôt que le workdir SFS partagé (option de production, décommenter dans `nextflow.config`)

### Petits nœuds vs gros nœuds

| Stratégie | Exemple | Jobs STAR simultanés | Avantages | Inconvénients |
|---|---|---|---|---|
| Petits nœuds | 10 × 8 vCPU / 64 GB | 10 (1/nœud) | Autoscaling granulaire, isolation mémoire, panne isolée | Plus de nœuds à gérer, overhead K8s |
| Nœuds moyens | 3 × 32 vCPU / 256 GB | 12 (4/nœud) | Meilleur ratio coût/job, moins d'overhead | Panne = 4 jobs simultanément |
| Gros nœuds | 1 × 64 vCPU / 512 GB | 9 (512/52 GB) | Un seul nœud à gérer | Sous-utilisation CPU garantie, coût fixe même inactif |

**Conclusion** : pour RNA-seq bulk (workload embarrassingly parallel par sample), les nœuds moyens offrent le meilleur compromis. Les très gros nœuds sont pertinents uniquement pour le de novo assembly ou GATK scatter/gather intensif.

### Recommandations par workload NovaSeq

```
RNA-seq bulk (STAR + Salmon)   → 16 vCPU / 128 GB  → 2 jobs STAR/nœud
WGS (BWA-MEM2 + GATK)         → 32 vCPU / 256 GB  → 4 jobs BWA/nœud
De novo assembly               → 1 nœud dédié, RAM maximale disponible
Pipeline multi-outil mixte     → 2 pools : petit (orchestration), grand (alignement)
```

**Sur Scaleway Kapsule** :
- `POP2-HM-8C-64G` → 1 job STAR/nœud (POC, simple à valider)
- `POP2-HM-32C-256G` → 4 jobs STAR/nœud (production, meilleur ratio coût/job)
- `POP2-HM-64C-512G` → sous-utilisation CPU → déconseillé pour RNA-seq pur

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
