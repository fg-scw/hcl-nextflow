#!/usr/bin/env bash
# Prépare les données de démo : télécharge SRR1039508 (human airway, GRCh38-compatible)
# et les uploade dans le bucket S3 input avec la samplesheet prête à l'emploi.
#
# À lancer une fois après 'make cluster' et avant 'make run-pipeline'.
# Le bucket S3 et ses credentials sont lus depuis les outputs Terraform.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TF="${SCRIPT_DIR}/../terraform"

for cmd in aws curl terraform; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERREUR : commande '$cmd' introuvable." && exit 1
  fi
done

INPUT_BUCKET=$(terraform -chdir="$TF" output -raw input_bucket_name)
S3_ENDPOINT="https://s3.fr-par.scw.cloud"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

printf '\n=== Préparation données de démo : SRR1039508 ===\n'
printf '  Source  : ENA / SRA (Himes et al. 2014, human airway smooth muscle cells)\n'
printf '  Dataset : 50 000 reads PE ~63 bp, TruSeq RNA non-stranded, GRCh38-compatible\n'
printf '  Bucket  : s3://%s/smoke/\n\n' "$INPUT_BUCKET"

# Télécharger les 50K premières paires de reads depuis ENA
for mate in 1 2; do
  printf '  Téléchargement SRR1039508_%s.fastq.gz ...\n' "$mate"
  curl -fL --retry 3 --silent --show-error \
    "https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR103/008/SRR1039508/SRR1039508_${mate}.fastq.gz" \
    | gunzip -c | head -200000 | gzip \
    > "${TMP_DIR}/SRR1039508_${mate}.fastq.gz"
  SIZE=$(ls -lh "${TMP_DIR}/SRR1039508_${mate}.fastq.gz" | awk '{print $5}')
  printf '    → %s\n' "$SIZE"
done

# Créer la samplesheet
cat > "${TMP_DIR}/samplesheet.csv" <<EOF
sample,fastq_1,fastq_2,strandedness
SRR1039508,s3://${INPUT_BUCKET}/smoke/SRR1039508_1.fastq.gz,s3://${INPUT_BUCKET}/smoke/SRR1039508_2.fastq.gz,unstranded
EOF

printf '\n  Upload vers s3://%s/ ...\n' "$INPUT_BUCKET"
aws --endpoint-url "$S3_ENDPOINT" s3 sync \
  "${TMP_DIR}/" "s3://${INPUT_BUCKET}/smoke/" \
  --exclude "samplesheet.csv" --only-show-errors
aws --endpoint-url "$S3_ENDPOINT" s3 cp \
  "${TMP_DIR}/samplesheet.csv" "s3://${INPUT_BUCKET}/samplesheet.csv" \
  --only-show-errors

printf '\nDone. Contenu du bucket :\n'
aws --endpoint-url "$S3_ENDPOINT" s3 ls "s3://${INPUT_BUCKET}/" --recursive --human-readable

printf '\nPrêt pour : make run-pipeline\n'
