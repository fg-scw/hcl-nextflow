TERRAFORM_DIR := terraform
SCRIPTS_DIR   := scripts
TF            := terraform -chdir=$(TERRAFORM_DIR)
KUBECONFIG    ?= $(HOME)/.kube/config-nf-kapsule
NAMESPACE     := bioinformatics

export KUBECONFIG

.PHONY: init cluster deploy-and-smoke kubeconfig status upload-reference smoke-test run-pipeline clean \
        watch-pods watch-nodes scale-check logs-autoscaler fmt outputs

# ── Infrastructure ────────────────────────────────────────────────────────────

init: ## Initialiser Terraform (providers)
	$(TF) init -upgrade

cluster: ## Déployer le cluster Kapsule + node pools + SFS + S3 + IAM + K8s resources
	@echo "=== Phase 0 : VPC + Private Network ==="
	$(TF) apply -var-file=terraform.tfvars -auto-approve \
		-target=scaleway_vpc.main \
		-target=scaleway_vpc_private_network.main
	@echo "=== Phase 1 : cluster Scaleway + node pools ==="
	$(TF) apply -var-file=terraform.tfvars -auto-approve \
		-target=scaleway_k8s_pool.orchestrator \
		-target=scaleway_k8s_pool.star_compute
	@echo "=== Installation du kubeconfig hors du graphe Terraform ==="
	@CLUSTER_ID=$$($(TF) output -raw cluster_id) && \
	scw k8s kubeconfig install $$CLUSTER_ID
	@echo "=== Attente stabilisation API K8s (60s) ==="
	@sleep 60
	@echo "=== Phase 2 : ressources Kubernetes (namespace, RBAC, PVCs, ConfigMap) ==="
	$(TF) apply -var-file=terraform.tfvars -auto-approve

deploy-and-smoke: init cluster smoke-test ## Déployer l'infrastructure puis lancer le test bout-en-bout

kubeconfig: ## Configurer kubectl avec le kubeconfig du cluster
	@CLUSTER_ID=$$($(TF) output -raw cluster_id) && \
	scw k8s kubeconfig install $$CLUSTER_ID
	@echo "KUBECONFIG=$(KUBECONFIG)"
	kubectl get nodes -o wide

status: ## État des nœuds, PVCs et pods du namespace bioinformatics
	@echo "\n=== Nœuds ===" && kubectl get nodes -o wide
	@echo "\n=== PVCs ===" && kubectl get pvc -n $(NAMESPACE)
	@echo "\n=== Pods ===" && kubectl get pods -n $(NAMESPACE)
	@kubectl top nodes 2>/dev/null || true

clean: ## Destroy complet (⚠ supprime cluster, données S3 et volumes SFS)
	$(TF) destroy -var-file=terraform.tfvars -auto-approve

# ── Pipeline ──────────────────────────────────────────────────────────────────

upload-reference: ## Générer l'index STAR GRCh38 dans le PVC reference (one-shot, ~4-6h)
	bash $(SCRIPTS_DIR)/bootstrap-reference.sh

smoke-test: ## Tester automatiquement S3 → Kapsule → nf-core/rnaseq → S3
	bash $(SCRIPTS_DIR)/smoke-test.sh

run-pipeline: ## Lancer nf-core/rnaseq sur le cluster Kapsule
	bash $(SCRIPTS_DIR)/run-pipeline.sh

# ── Diagnostic ────────────────────────────────────────────────────────────────

watch-pods: ## Surveiller les pods du namespace bioinformatics en temps réel
	kubectl get pods -n $(NAMESPACE) -w

watch-nodes: ## Surveiller les nœuds et leur type (scale up/down)
	watch -n 10 kubectl get nodes \
	  -o custom-columns=\
'NAME:.metadata.name,\
TYPE:.metadata.labels.node\.kubernetes\.io/instance-type,\
POOL:.metadata.labels.k8s\.scaleway\.com/pool-name,\
STATUS:.status.conditions[-1].type'

scale-check: ## État du Cluster Autoscaler et événements récents
	@echo "\n=== Autoscaler status ===" && \
	kubectl describe configmap -n kube-system cluster-autoscaler-status 2>/dev/null | head -40 || true
	@echo "\n=== Événements récents ===" && \
	kubectl get events -n $(NAMESPACE) --sort-by='.lastTimestamp' | tail -20

logs-autoscaler: ## Logs du Cluster Autoscaler
	kubectl logs -n kube-system -l app=cluster-autoscaler --tail=50 -f

fmt: ## Formater les fichiers Terraform
	$(TF) fmt -recursive

outputs: ## Afficher tous les outputs Terraform
	$(TF) output
