#!/usr/bin/env bash
# Lance nf-core/rnaseq sur le cluster Kapsule.
# Prérequis : 'make cluster' exécuté et kubectl configuré.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
TF="${REPO_ROOT}/terraform"
NS="bioinformatics"
NF_VERSION="3.14.0"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-nf-kapsule}"

# ── Vérifications préalables ──────────────────────────────────────────────────
for command in jq kubectl scw terraform; do
  if ! command -v "$command" &>/dev/null; then
    echo "ERREUR : commande '$command' introuvable."
    exit 1
  fi
done

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

RUN_DATE=$(date +%Y%m%d-%H%M%S)
OUTDIR="s3://${RESULTS_BUCKET}/run-${RUN_DATE}"

printf '\n=== nf-core/rnaseq v%s sur Kapsule ===\n' "$NF_VERSION"
printf '  Namespace     : %s\n' "$NS"
printf '  Input bucket  : s3://%s\n' "$INPUT_BUCKET"
printf '  Results dir   : %s\n' "$OUTDIR"
printf '  Kubeconfig    : %s\n\n' "$KUBECONFIG"

# ── Lancement du head Nextflow dans le pool orchestrateur ────────────────────
source "${SCRIPT_DIR}/launch-nextflow-job.sh"
launch_nextflow_job \
  "run-${RUN_DATE}" \
  "scaleway_kapsule" \
  "s3://${INPUT_BUCKET}/samplesheet.csv" \
  "$OUTDIR" \
  "${REPO_ROOT}/nextflow/params.yaml" \
  "$@"
