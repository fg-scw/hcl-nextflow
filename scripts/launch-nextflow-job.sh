#!/usr/bin/env bash
# À sourcer : lance le processus head Nextflow dans le pool orchestrateur.

NEXTFLOW_IMAGE="${NEXTFLOW_IMAGE:-nextflow/nextflow:25.10.4}"

launch_nextflow_job() {
  local run_id="$1"
  local profile="$2"
  local input="$3"
  local outdir="$4"
  local params_file="$5"
  shift 5

  local job_name="nextflow-${run_id}"
  local config_name="${job_name}-config"
  local pod phase args_json
  local -a nf_args config_args

  nf_args=(
    -c /config/nextflow.config
    run nf-core/rnaseq
    -r "${NF_VERSION:-3.14.0}"
    -profile "$profile"
    --input "$input"
    --outdir "$outdir"
    -resume
  )
  config_args=(create configmap "$config_name" -n bioinformatics
    --from-file=nextflow.config="${REPO_ROOT}/nextflow/nextflow.config")

  if [[ -n "$params_file" ]]; then
    nf_args+=(-params-file /config/params.yaml)
    config_args+=(--from-file=params.yaml="$params_file")
  fi
  nf_args+=("$@")

  config_args+=(--dry-run=client -o json)
  kubectl "${config_args[@]}" | kubectl apply -f - >/dev/null

  args_json=$(jq -cn --args '$ARGS.positional' -- "${nf_args[@]}")
  kubectl create job "$job_name" -n bioinformatics \
    --image="$NEXTFLOW_IMAGE" --dry-run=client -o json \
    | jq --argjson args "$args_json" --arg config_name "$config_name" '
        .spec.backoffLimit = 0 |
        .spec.ttlSecondsAfterFinished = 3600 |
        .spec.template.spec.serviceAccountName = "nextflow" |
        .spec.template.spec.nodeSelector = {"k8s.scaleway.com/pool-name": "orchestrator"} |
        .spec.template.spec.containers[0].command = ["nextflow"] |
        .spec.template.spec.containers[0].args = $args |
        .spec.template.spec.containers[0].workingDir = "/data/workdir" |
        .spec.template.spec.containers[0].resources = {
          requests: {cpu: "500m", memory: "1Gi"},
          limits: {cpu: "2", memory: "4Gi"}
        } |
        .spec.template.spec.containers[0].env = [
          {name: "AWS_ACCESS_KEY_ID", valueFrom: {secretKeyRef: {name: "pipeline-s3-credentials", key: "access-key"}}},
          {name: "AWS_SECRET_ACCESS_KEY", valueFrom: {secretKeyRef: {name: "pipeline-s3-credentials", key: "secret-key"}}},
          {name: "AWS_ENDPOINT_URL_S3", valueFrom: {secretKeyRef: {name: "pipeline-s3-credentials", key: "s3-endpoint"}}},
          {name: "NXF_HOME", value: "/data/workdir/.nextflow"}
        ] |
        .spec.template.spec.containers[0].volumeMounts = [
          {name: "workdir",    mountPath: "/data/workdir"},
          {name: "reference",  mountPath: "/data/reference", readOnly: true},
          {name: "config",     mountPath: "/config",         readOnly: true}
        ] |
        .spec.template.spec.volumes = [
          {name: "workdir",   persistentVolumeClaim: {claimName: "nf-workdir-pvc"}},
          {name: "reference", persistentVolumeClaim: {claimName: "nf-reference-pvc"}},
          {name: "config",    configMap: {name: $config_name}}
        ]' \
    | kubectl apply -f - >/dev/null

  printf '\nJob Nextflow créé : %s (image %s)\n' "$job_name" "$NEXTFLOW_IMAGE"

  pod=""
  for _ in $(seq 1 300); do
    pod=$(kubectl get pod -n bioinformatics -l "job-name=$job_name" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "$pod" ]]; then
      phase=$(kubectl get pod "$pod" -n bioinformatics -o jsonpath='{.status.phase}')
      if [[ "$phase" != "Pending" ]]; then
        break
      fi
    fi
    sleep 2
  done

  if [[ -z "$pod" || "$phase" == "Pending" ]]; then
    echo "ERREUR : le pod head Nextflow n'a pas démarré."
    kubectl describe job "$job_name" -n bioinformatics
    return 1
  fi

  kubectl logs -n bioinformatics -f "$pod" || true

  # Le conteneur peut être terminé avant que le contrôleur Job ait publié
  # status.succeeded. Attendre cette courte propagation évite un faux échec.
  kubectl wait --for=condition=complete "job/$job_name" -n bioinformatics \
    --timeout=60s >/dev/null 2>&1 || true

  if [[ "$(kubectl get job "$job_name" -n bioinformatics -o jsonpath='{.status.succeeded}')" != "1" ]]; then
    echo "ERREUR : le Job Nextflow a échoué ; ressources conservées pour diagnostic."
    kubectl describe pod "$pod" -n bioinformatics
    return 1
  fi

  kubectl delete configmap "$config_name" -n bioinformatics --ignore-not-found >/dev/null
  printf '\nPipeline terminé : %s\n' "$outdir"
}
