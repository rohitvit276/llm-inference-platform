# Runbook for the whole platform. Typical session:
#   make up deploy-infra build deploy    ... work / load test ...   make down
REGION      ?= ap-south-1
CLUSTER     ?= llm-platform
TAG         ?= $(shell git rev-parse --short HEAD)
ECR         = $(shell cd terraform && terraform output -raw ecr_gateway_url)

.PHONY: up kubeconfig deploy-infra build deploy loadtest grafana down

## Create the EKS cluster + ECR + budget alarm (~12 min)
up:
	cd terraform && terraform init && terraform apply

kubeconfig:
	aws eks update-kubeconfig --region $(REGION) --name $(CLUSTER)

## Install cluster addons: monitoring stack + KEDA
deploy-infra: kubeconfig
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo add kedacore https://kedacore.github.io/charts
	helm repo update
	helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
		-n monitoring --create-namespace -f monitoring/kube-prometheus-stack-values.yaml --wait
	helm upgrade --install keda kedacore/keda -n keda --create-namespace --wait

## Build & push the gateway image to ECR
build:
	aws ecr get-login-password --region $(REGION) | docker login --username AWS --password-stdin $(ECR)
	docker build -t $(ECR):$(TAG) app/gateway
	docker push $(ECR):$(TAG)

## Deploy / upgrade the LLM platform chart
deploy:
	helm upgrade --install llm-platform deploy/helm/llm-platform \
		--set gateway.image=$(ECR):$(TAG)
	kubectl get svc llm-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'; echo

## Run the k6 load test (set GATEWAY_URL from `make deploy` output)
loadtest:
	k6 run -e GATEWAY_URL=$(GATEWAY_URL) -e API_KEY=dev-key loadtest/chat.js

grafana:
	@echo "http://localhost:3000  (admin/admin)"
	kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80

## Tear EVERYTHING down — run this at the end of every session!
down:
	-helm uninstall llm-platform
	cd terraform && terraform destroy
