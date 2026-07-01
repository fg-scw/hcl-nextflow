# Troubleshooting & Notes techniques

Ce document regroupe les problèmes rencontrés lors de la validation du POC (2026-07-01), les contraintes de déploiement connues, et les recommandations de dimensionnement pour la production.

---

## Bugs identifiés et corrigés

11 problèmes rencontrés et résolus lors de la validation complète du pipeline nf-core/rnaseq v3.14.0 sur Scaleway Kapsule.

| # | Composant | Symptôme | Cause racine | Correction |
|---|---|---|---|---|
| 1 | Pod head Nextflow | `file or directory does not exist` au démarrage | `nf-reference-pvc` non monté dans le pod head → Nextflow ne peut pas valider les chemins `fasta`/`gtf` | Montage ajouté dans `launch-nextflow-job.sh` (volumes + volumeMounts) |
| 2 | `PREPARE_GENOME:GTF_FILTER` | `FileNotFoundError: genes.gtf` | `nf-reference-pvc` absent des pods task (seul le pod head le montait) | Directive `k8s.pod = [[volumeClaim: 'nf-reference-pvc', ...]]` dans `nextflow.config` — monte le PVC sur **tous** les pods task |
| 3 | `TRIMGALORE` / `FASTQC` | Pods en `Pending` indéfiniment | Demandaient 7 ou 4 CPU → non-schedulables sur orchestrateur 4 vCPU | `withName: '.*TRIM.*\|.*FASTQC.*' { cpus=2, memory='8.GB' }` |
| 4 | `MAKE_TRANSCRIPTS_FASTA` / `SALMON_INDEX` | Pods `Pending` (8 CPU demandés) | Labels nf-core `withLabel 'process_high'` (12 CPU) cappés par `max_cpus=8` dans `params.yaml` — mais `params.yaml` a priorité sur `nextflow.config` et écrase les `withName` | (a) `withName: '.*' { cpus=2 }` placé **en premier** dans `process {}` ; (b) `max_cpus`/`max_memory` retirés de `params.yaml` |
| 5 | `SALMON_INDEX` | OOM kill (exit 137) | pufferfish charge `gentrome.fa` (transcriptome + génome GRCh38 décoy, ~3,3 Go) entièrement en RAM = 30-40 GB requis. Pool orchestrateur (16 GB) insuffisant | `withName: '.*SALMON_INDEX.*'` routé sur `star-compute` (64 GB), 32 GB alloués, nodeSelector + toleration `workload=star-compute:NoSchedule` |
| 6 | `FASTQ_SUBSAMPLE_FQ_SALMON:SALMON_QUANT` | OOM kill (exit 137) puis exit 1 (0 fragments assignés) | (a) Détection strandedness (`strandedness=auto`) charge l'index Salmon complet même avec `--skipQuant` ; (b) 50K reads test → trop peu de fragments assignés | `withName: '.*SALMON_QUANT.*'` sur `star-compute` avec 24 GB ; samplesheet modifié : `strandedness=unstranded` → sous-workflow de détection éliminé |
| 7 | `STAR_ALIGN_IGENOMES` | exit 102 (incompatibilité version STAR) | `star_index` dans `params.yaml` pointait vers un index construit par `bootstrap-reference.sh` avec STAR 2.7.10b. Le container nf-core `STAR_ALIGN_IGENOMES` utilise STAR 2.6.1d, incompatible | `star_index` désactivé dans `params.yaml` → nf-core génère l'index via `STAR_GENOMEGENERATE_IGENOMES` (même container STAR 2.6.1d, index compatible) |
| 8 | `STAR_ALIGN_IGENOMES` | exit 0 mais 0 reads alignés, `genomeFileSizes 0` dans Log.out | Double montage `/data/reference` : `k8s.pod` global **plus** `volumeClaim` dans `withName:STAR_ALIGN` → K8s rejette le pod (422 Unprocessable Entity, mountPath dupliqué) → STAR démarre avec un `genomeDir` vide | Suppression des entrées `volumeClaim: nf-reference-pvc` dans `withName:STAR_ALIGN` et `withName:STAR_GENOMEGENERATE` (le montage global suffit) |
| 9 | Nextflow `-resume` | `SALMON_QUANT` reçoit toujours 0 fragments après correction du bug #8 | STAR avait produit un BAM vide (exit 0), Nextflow l'avait mis en cache. `-resume` réutilisait silencieusement ce résultat corrompu. Impossible d'invalider une seule entrée du cache SQLite Nextflow sans accès au DB | `launch-nextflow-job.sh` modifié : `-resume` **désactivé par défaut** (opt-in via `NXF_RESUME=1`). Run propre sans cache → STAR régénère un BAM correct |
| 10 | Autoscaler `star-compute` | Nœuds non provisionnés | `MEMORY3-X8C-64G` indisponible en `fr-par-1` le 2026-07-01 | `terraform.tfvars` : `compute_node_type = "POP2-HM-8C-64G"` (même ratio RAM/vCPU 8 GB/vCPU, disponible en fr-par-1) |
| 11 | `STAR_ALIGN_IGENOMES` | 100% reads "too short" (0 alignements) | Les FASTQs nf-core (`testdata/GSE110004/SRR6357070_*.fastq.gz`) contiennent `kraken:taxid\|4932` dans les headers = *Saccharomyces cerevisiae* (levure). Conçus pour le profil `test` nf-core avec le génome R64-1-1, pas pour GRCh38 | Remplacement par `SRR1039508` (Himes et al. 2014, human airway smooth muscle cells, HiSeq 2000, TruSeq RNA non-stranded) — `make prepare-demo` automatise le téléchargement |

---

## Contraintes connues

### Déploiement en trois phases

`make cluster` enchaîne automatiquement trois `terraform apply` successifs :

- **Phase 0** : VPC + Private Network (propagation dans l'API Scaleway avant la suite)
- **Phase 1** : cluster Kapsule + node pools, puis `scw k8s kubeconfig install` hors du graphe Terraform
- **Attente 60s** : laisse le control plane K8s devenir joignable avant que le provider `kubernetes` ne s'y connecte
- **Phase 2** : namespace, RBAC, PVCs SFS, ConfigMap, Secret Kubernetes

Ne pas interrompre entre les phases. Le cluster conserve `delete_additional_resources = false` afin qu'un remplacement Kapsule ne supprime pas le Private Network géré par Terraform. Si un ancien déploiement a laissé un ID de PN orphelin dans le state, relancer `make cluster` : le refresh Phase 0 détectera sa disparition et le recréera.

Le provider `kubernetes` (`terraform/main.tf`) lit `~/.kube/config-nf-kapsule`, installé par la CLI Scaleway entre les phases 1 et 2. Ce fichier n'est pas une ressource Terraform : un remplacement Kapsule le fait pointer vers `localhost:80` (`connection refused`). Toujours relancer `make cluster` après un remplacement de cluster.

### STAR OOM

40 GB minimum stricts par job (index GRCh38 chargé intégralement en RAM). STAR échoue silencieusement (OOM kill, exit 137) sans message explicite en dessous de ce seuil. Le POC alloue 52 GB/job sur `POP2-HM-8C-64G` (1 job/nœud). Pour augmenter le packing en production : `POP2-HM-32C-256G` (4 jobs/nœud, 52 GB × 4 = 208 GB sur 256 GB disponibles).

### SFS CSI driver

Activé par le tag `scw-filestorage-csi` au niveau du cluster. Compatible POP2. Vérifier après déploiement :

```bash
kubectl get daemonset -n kube-system filestorage-csi-node
```

### `nf-reference-pvc` — deux points de montage requis

1. **Pod head Nextflow** (`scripts/launch-nextflow-job.sh`) : Nextflow valide l'existence des chemins `fasta`/`gtf` au démarrage. Sans montage de `nf-reference-pvc` à `/data/reference`, la validation échoue immédiatement avec `file or directory does not exist`.

2. **Tous les pods task** (`nextflow/nextflow.config`, bloc `k8s {}`): les tâches `PREPARE_GENOME` (GTF_FILTER, GETCHROMSIZES, GTF2BED, MAKE_TRANSCRIPTS_FASTA, SALMON_INDEX) accèdent aux fichiers de référence via symlink depuis le workdir. La directive `k8s.pod` dans `nextflow.config` monte le PVC sur tous les pods task. Ne pas ajouter un `volumeClaim` supplémentaire dans les `withName` STAR — cela provoque un double montage du même PVC (K8s 422 Unprocessable Entity).

### Ressources task vs capacité orchestrateur

`TRIMGALORE` et `FASTQC` s'exécutent sur le pool orchestrateur (pas de taint). Avec le pod head (~500m CPU / 1Gi) et les pods système (~500m CPU), il reste ~2-3 vCPU / 13 GB disponibles sur un nœud 4 vCPU / 16 GB. Configurer `cpus > 3` pour ces tâches bloque le scheduling définitivement.

### Index STAR et compatibilité des versions

L'index généré par `make upload-reference` utilise STAR 2.7.10b. Le container nf-core `STAR_ALIGN_IGENOMES` utilise STAR 2.6.1d — ces deux versions sont **incompatibles** (exit 102 au chargement). Sur un nouveau cluster, laisser `star_index` commenté dans `params.yaml` : nf-core génère l'index via `STAR_GENOMEGENERATE_IGENOMES` (même container STAR 2.6.1d → compatible). Après le premier run, retrouver le chemin de l'index dans le workdir SFS et le renseigner dans `params.yaml` pour éviter de le régénérer à chaque run.

### Params invalides en v3.14.0

`--read_length` et `--strandedness` ne sont plus des paramètres top-level valides (déplacés au niveau de la samplesheet, colonne `strandedness`). Les inclure dans `params.yaml` génère des WARNs non-bloquants mais pollue les logs.

### Pas de Spot sur Kapsule

Scaleway ne propose pas d'instances préemptibles. Le Cluster Autoscaler scale le pool `star-compute` à 0 entre les runs. Utiliser `NXF_RESUME=1 make run-pipeline` pour reprendre après une interruption (uniquement si les outputs précédents sont valides — voir bug #9).

---

## Upload des FASTQs NovaSeq

Les FASTQ proviennent du séquenceur NovaSeq (on-premise) et doivent être uploadés dans le bucket S3 input avant chaque run.

### Extraire les credentials S3

Les credentials IAM pipeline sont stockés dans le secret Kubernetes :

```bash
ACCESS_KEY=$(kubectl get secret pipeline-s3-credentials -n bioinformatics \
  -o jsonpath='{.data.access-key}' | base64 -d)
SECRET_KEY=$(kubectl get secret pipeline-s3-credentials -n bioinformatics \
  -o jsonpath='{.data.secret-key}' | base64 -d)
```

### Scénario A — Copie directe NAS → S3 (recommandé POC)

```bash
RUN_ID="run-$(date +%Y%m%d)"
AWS_ACCESS_KEY_ID="$ACCESS_KEY" \
AWS_SECRET_ACCESS_KEY="$SECRET_KEY" \
aws --endpoint-url https://s3.fr-par.scw.cloud \
    s3 sync /nas/fastq/run-DATE/ s3://nf-kapsule-input/$RUN_ID/ \
    --no-progress --exclude "*.tmp" --include "*.fastq.gz"
```

### Scénario B — Scaleway Interlink (Direct Connect, production)

Connexion privée dédiée entre le datacenter on-premise et le réseau Scaleway via BGP. Le NAS est accessible depuis les pods Kapsule sur le Private Network sans passer par Internet. Nécessite un port Interlink commandé chez Scaleway et la modification de `nextflow.config` pour monter le NAS comme volume supplémentaire dans les pods task.

### Scénario C — VPN site-à-site

VPN IPsec ou WireGuard entre le réseau on-premise et le Private Network Kapsule. Moins de débit que l'Interlink mais sans engagement de port dédié.

### Générer la samplesheet depuis S3

```bash
RUN_ID="run-$(date +%Y%m%d)"
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

AWS_ACCESS_KEY_ID="$ACCESS_KEY" \
AWS_SECRET_ACCESS_KEY="$SECRET_KEY" \
aws --endpoint-url https://s3.fr-par.scw.cloud \
    s3 cp samplesheet.csv s3://nf-kapsule-input/$RUN_ID/samplesheet.csv
```

Adapter le pattern `sed` selon la convention de nommage (NextSeq, custom bcl2fastq, etc.).

---

## Configuration pour les vrais runs NovaSeq

Adapter `nextflow/params.yaml` avant chaque run :

```yaml
input:  "s3://nf-kapsule-input/run-DATE/samplesheet.csv"
outdir: "s3://nf-kapsule-results/run-DATE"

fasta: "/data/reference/fasta/genome.fa"
gtf:   "/data/reference/gtf/genes.gtf"

# Index STAR généré par nf-core au premier run (STAR 2.6.1d, compatible STAR_ALIGN_IGENOMES)
# Retrouver le chemin dans le workdir SFS après le premier run et le décommenter :
# star_index: "/data/workdir/<hash>/star"
```

---

## Dimensionnement des nœuds

### La RAM prime sur le CPU

Pour les outils d'alignement, la RAM est le facteur limitant :

| Outil | RAM requise | CPU utile |
|---|---|---|
| STAR (GRCh38) | **32 GB** (index chargé intégralement en RAM) | 8-16 threads |
| BWA-MEM2 (hg38) | **60 GB** | 16-32 threads |
| HISAT2 (GRCh38) | ~8 GB | 8-16 threads |
| Salmon quant | 2-4 GB | 4-8 threads |
| FastQC / Trimming | <4 GB | 4 threads |

STAR échoue silencieusement (OOM kill) si la RAM disponible est inférieure à 40 GB pour GRCh38.

### Petits nœuds vs gros nœuds

| Stratégie | Exemple | Jobs STAR simultanés | Avantages | Inconvénients |
|---|---|---|---|---|
| Petits nœuds | 10 × 8 vCPU / 64 GB | 10 (1/nœud) | Autoscaling granulaire, isolation mémoire | Plus d'overhead K8s |
| Nœuds moyens | 3 × 32 vCPU / 256 GB | 12 (4/nœud) | Meilleur ratio coût/job | Panne = 4 jobs simultanément |
| Gros nœuds | 1 × 64 vCPU / 512 GB | 9 (512/52 GB) | Un seul nœud | Sous-utilisation CPU garantie |

Pour RNA-seq bulk (workload embarrassingly parallel par sample), les nœuds moyens offrent le meilleur compromis.

### Recommandations par workload NovaSeq sur Scaleway Kapsule

```
RNA-seq bulk (STAR + Salmon)   → POP2-HM-32C-256G  → 4 jobs STAR/nœud
WGS (BWA-MEM2 + GATK)         → POP2-HM-32C-256G  → 4 jobs BWA/nœud
De novo assembly               → 1 nœud dédié, RAM maximale disponible
POC / validation               → POP2-HM-8C-64G    → 1 job STAR/nœud (ce repo)
```
