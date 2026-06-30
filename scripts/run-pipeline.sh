#!/usr/bin/env bash
# Lance nf-core/rnaseq sur le cluster Kapsule.
# Prérequis : 'make cluster' exécuté, kubectl configuré, Nextflow installé (>= 23.10).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
TF="${REPO_ROOT}/terraform"
NS="bioinformatics"
NF_VERSION="3.14.0"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-nf-kapsule}"

# ── Vérifications préalables ──────────────────────────────────────────────────
if ! command -v nextflow &>/dev/null; then
  echo "ERREUR : nextflow introuvable. Installer depuis https://www.nextflow.io/docs/latest/install.html"
  exit 1
fi

if ! kubectl get namespace "$NS" &>/dev/null; then
  echo "ERREUR : namespace '$NS' absent. Exécuter 'make cluster' d'abord."
  exit 1
fi

# ── Récupération des outputs Terraform ───────────────────────────────────────
INPUT_BUCKET=$(terraform -chdir="$TF" output -raw input_bucket_name 2>/dev/null || true)
RESULTS_BUCKET=$(terraform -chdir="$TF" output -raw results_bucket_name 2>/dev/null || true)

if [[ -z "${INPUT_BUCKET:-}" || -z "${RESULTS_BUCKET:-}" ]]; then
  echo "ERREUR : outputs Terraform manquants. Exécuter 'make cluster' d'abord."
  exit 1
fi

# ── Credentials S3 depuis le Secret K8s ──────────────────────────────────────
ACCESS_KEY=$(kubectl get secret pipeline-s3-credentials -n "$NS" \
  -o jsonpath='{.data.access-key}' | base64 -d)
SECRET_KEY=$(kubectl get secret pipeline-s3-credentials -n "$NS" \
  -o jsonpath='{.data.secret-key}' | base64 -d)
S3_ENDPOINT="https://s3.fr-par.scw.cloud"

RUN_DATE=$(date +%Y%m%d-%H%M)
OUTDIR="s3://${RESULTS_BUCKET}/run-${RUN_DATE}"

printf '\n=== nf-core/rnaseq v%s sur Kapsule ===\n' "$NF_VERSION"
printf '  Namespace     : %s\n' "$NS"
printf '  Input bucket  : s3://%s\n' "$INPUT_BUCKET"
printf '  Results dir   : %s\n' "$OUTDIR"
printf '  Kubeconfig    : %s\n\n' "$KUBECONFIG"

# ── Lancement Nextflow ────────────────────────────────────────────────────────
AWS_ACCESS_KEY_ID="$ACCESS_KEY" \
AWS_SECRET_ACCESS_KEY="$SECRET_KEY" \
AWS_ENDPOINT_URL_S3="$S3_ENDPOINT" \
NXF_ANSI_LOG=true \
nextflow run "nf-core/rnaseq" \
  -r "$NF_VERSION" \
  -profile scaleway_kapsule \
  -c "${REPO_ROOT}/nextflow/nextflow.config" \
  -params-file "${REPO_ROOT}/nextflow/params.yaml" \
  --input "s3://${INPUT_BUCKET}/samplesheet.csv" \
  --outdir "$OUTDIR" \
  -resume \
  -with-report "${REPO_ROOT}/reports/run-${RUN_DATE}-report.html" \
  -with-timeline "${REPO_ROOT}/reports/run-${RUN_DATE}-timeline.html" \
  "$@"
