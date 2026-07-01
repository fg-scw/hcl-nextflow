#!/usr/bin/env bash
# Smoke test bout-en-bout : jeu officiel nf-core → Scaleway S3 → Kapsule → S3.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
TF="${REPO_ROOT}/terraform"
NS="bioinformatics"
NF_VERSION="3.14.0"
FASTQ_BASE="https://raw.githubusercontent.com/nf-core/test-datasets/rnaseq/testdata/GSE110004"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-nf-kapsule}"

for command in aws base64 curl jq kubectl scw terraform; do
  if ! command -v "$command" &>/dev/null; then
    echo "ERREUR : commande '$command' introuvable."
    exit 1
  fi
done

if ! kubectl get namespace "$NS" &>/dev/null; then
  echo "ERREUR : namespace '$NS' absent. Exécuter 'make cluster' d'abord."
  exit 1
fi

INPUT_BUCKET=$(terraform -chdir="$TF" output -raw input_bucket_name)
RESULTS_BUCKET=$(terraform -chdir="$TF" output -raw results_bucket_name)
ACCESS_KEY=$(kubectl get secret pipeline-s3-credentials -n "$NS" \
  -o jsonpath='{.data.access-key}' | base64 -d)
SECRET_KEY=$(kubectl get secret pipeline-s3-credentials -n "$NS" \
  -o jsonpath='{.data.secret-key}' | base64 -d)
S3_ENDPOINT="https://s3.fr-par.scw.cloud"
S3_PREFIX="smoke"
RUN_DATE=$(date +%Y%m%d-%H%M%S)
OUTDIR="s3://${RESULTS_BUCKET}/smoke-${RUN_DATE}"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

printf '\n=== Préparation du smoke test nf-core/rnaseq ===\n'
printf '  Dataset        : GSE110004 / SRR6357070 (test officiel nf-core)\n'
printf '  Input          : s3://%s/%s/\n' "$INPUT_BUCKET" "$S3_PREFIX"
printf '  Results        : %s\n\n' "$OUTDIR"

for mate in 1 2; do
  file="SRR6357070_${mate}.fastq.gz"
  curl --fail --location --retry 3 --silent --show-error \
    --output "${TMP_DIR}/${file}" "${FASTQ_BASE}/${file}"
done

cat >"${TMP_DIR}/samplesheet.csv" <<EOF
sample,fastq_1,fastq_2,strandedness
SMOKE,s3://${INPUT_BUCKET}/${S3_PREFIX}/SRR6357070_1.fastq.gz,s3://${INPUT_BUCKET}/${S3_PREFIX}/SRR6357070_2.fastq.gz,auto
EOF

AWS_ACCESS_KEY_ID="$ACCESS_KEY" \
AWS_SECRET_ACCESS_KEY="$SECRET_KEY" \
aws --endpoint-url "$S3_ENDPOINT" s3 sync \
  "${TMP_DIR}/" "s3://${INPUT_BUCKET}/${S3_PREFIX}/" --only-show-errors

source "${SCRIPT_DIR}/launch-nextflow-job.sh"
launch_nextflow_job \
  "smoke-${RUN_DATE}" \
  "test,scaleway_kapsule,scaleway_smoke" \
  "s3://${INPUT_BUCKET}/${S3_PREFIX}/samplesheet.csv" \
  "$OUTDIR" \
  "" \
  --max_cpus 2 \
  --max_memory 8.GB

MULTIQC_KEY="smoke-${RUN_DATE}/multiqc/star_salmon/multiqc_report.html"
AWS_ACCESS_KEY_ID="$ACCESS_KEY" \
AWS_SECRET_ACCESS_KEY="$SECRET_KEY" \
aws --endpoint-url "$S3_ENDPOINT" s3api head-object \
  --bucket "$RESULTS_BUCKET" --key "$MULTIQC_KEY" >/dev/null

printf 'Smoke test validé : s3://%s/%s\n' "$RESULTS_BUCKET" "$MULTIQC_KEY"
