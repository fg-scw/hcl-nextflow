#!/usr/bin/env bash
# Télécharge et génère l'index STAR GRCh38 dans le PVC nf-reference-pvc.
# À exécuter une seule fois après 'make cluster'.
# Durée : ~4-6h (génération index STAR sur 16 cœurs).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NS="bioinformatics"
GENOME_VERSION="${GENOME_VERSION:-GRCh38}"
ENSEMBL_RELEASE="${ENSEMBL_RELEASE:-110}"
READ_LENGTH="${READ_LENGTH:-150}"
SJDB_OVERHANG=$((READ_LENGTH - 1))
THREADS=16

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-nf-kapsule}"

# ── Vérifications ─────────────────────────────────────────────────────────────
if ! kubectl get pvc nf-reference-pvc -n "$NS" &>/dev/null; then
  echo "ERREUR : PVC 'nf-reference-pvc' absent. Exécuter 'make cluster' d'abord."
  exit 1
fi

# Vérifier si l'index existe déjà
INDEX_EXISTS=$(kubectl run check-reference --restart=Never --rm --image=alpine \
  --namespace="$NS" \
  --overrides='{
    "spec": {
      "containers": [{"name":"check","image":"alpine",
        "command":["sh","-c","test -f /data/reference/star_index/'"${GENOME_VERSION}_${READ_LENGTH}bp"'/SA && echo EXISTS || echo MISSING"],
        "volumeMounts":[{"name":"ref","mountPath":"/data/reference"}]}],
      "volumes":[{"name":"ref","persistentVolumeClaim":{"claimName":"nf-reference-pvc"}}],
      "restartPolicy":"Never"
    }
  }' \
  -it --quiet 2>/dev/null || echo "MISSING")

if echo "$INDEX_EXISTS" | grep -q "EXISTS"; then
  echo "Index STAR ${GENOME_VERSION}_${READ_LENGTH}bp déjà présent dans nf-reference-pvc."
  echo "Supprimer /data/reference/star_index/${GENOME_VERSION}_${READ_LENGTH}bp pour forcer la regénération."
  exit 0
fi

printf '\n=== Bootstrap référence génomique ===\n'
printf '  Génome        : %s (Ensembl release %s)\n' "$GENOME_VERSION" "$ENSEMBL_RELEASE"
printf '  Read length   : %s bp (sjdbOverhang = %s)\n' "$READ_LENGTH" "$SJDB_OVERHANG"
printf '  Threads       : %s\n' "$THREADS"
printf '  Namespace     : %s\n\n' "$NS"

# ── Lancement du pod de génération d'index ────────────────────────────────────
kubectl apply -n "$NS" -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: bootstrap-reference
  namespace: ${NS}
  labels:
    app: bootstrap-reference
spec:
  restartPolicy: Never
  nodeSelector:
    k8s.scaleway.com/pool-name: "star-compute"
  tolerations:
    - key: "workload"
      value: "star-compute"
      operator: "Equal"
      effect: "NoSchedule"
  volumes:
    - name: reference
      persistentVolumeClaim:
        claimName: nf-reference-pvc
  initContainers:
    # Téléchargement du génome et des annotations Ensembl
    - name: download-genome
      image: curlimages/curl:8.5.0
      command:
        - sh
        - -c
        - |
          set -eu
          mkdir -p /data/reference/fasta /data/reference/gtf
          FASTA_URL="https://ftp.ensembl.org/pub/release-${ENSEMBL_RELEASE}/fasta/homo_sapiens/dna/Homo_sapiens.${GENOME_VERSION}.dna.primary_assembly.fa.gz"
          GTF_URL="https://ftp.ensembl.org/pub/release-${ENSEMBL_RELEASE}/gtf/homo_sapiens/Homo_sapiens.${GENOME_VERSION}.${ENSEMBL_RELEASE}.gtf.gz"
          echo "Téléchargement FASTA..."
          curl -fL -o /data/reference/fasta/genome.fa.gz "\$FASTA_URL"
          gunzip /data/reference/fasta/genome.fa.gz
          echo "Téléchargement GTF..."
          curl -fL -o /data/reference/gtf/genes.gtf.gz "\$GTF_URL"
          gunzip /data/reference/gtf/genes.gtf.gz
          echo "Téléchargement terminé."
      volumeMounts:
        - name: reference
          mountPath: /data/reference
      resources:
        requests:
          cpu: "2"
          memory: "4Gi"
  containers:
    # Génération de l'index STAR
    - name: star-genomegenerate
      image: quay.io/biocontainers/star:2.7.10b--h9ee0642_0
      command:
        - bash
        - -c
        - |
          set -eu
          INDEX_DIR="/data/reference/star_index/${GENOME_VERSION}_${READ_LENGTH}bp"
          mkdir -p "\$INDEX_DIR"
          echo "Génération index STAR (${THREADS} threads, sjdbOverhang=${SJDB_OVERHANG})..."
          STAR \
            --runMode genomeGenerate \
            --genomeDir "\$INDEX_DIR" \
            --genomeFastaFiles /data/reference/fasta/genome.fa \
            --sjdbGTFfile /data/reference/gtf/genes.gtf \
            --sjdbOverhang ${SJDB_OVERHANG} \
            --runThreadN ${THREADS} \
            --genomeSAindexNbases 14 \
            --outTmpDir /tmp/star-tmp
          echo "Index généré dans \$INDEX_DIR"
          ls -lh "\$INDEX_DIR"
      volumeMounts:
        - name: reference
          mountPath: /data/reference
      resources:
        requests:
          cpu: "${THREADS}"
          memory: "120Gi"
        limits:
          cpu: "${THREADS}"
          memory: "128Gi"
EOF

echo ""
echo "Pod 'bootstrap-reference' créé. Suivre les logs :"
echo "  kubectl logs -n $NS bootstrap-reference -c star-genomegenerate -f"
echo ""
echo "Durée estimée : 4-6h. Une fois terminé :"
echo "  kubectl delete pod bootstrap-reference -n $NS"
