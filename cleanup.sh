#!/usr/bin/env bash
# cleanup.sh — Tear down everything setup.sh created.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-lifecycle-demo}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"

GREEN='\033[0;32m'; NC='\033[0m'
info() { echo -e "${GREEN}[cleanup] $*${NC}"; }

AWSCLI="aws --endpoint-url=http://localhost:4566"
command -v lstk &>/dev/null && AWSCLI="lstk aws"

info "Deleting namespace 'demo'..."
kubectl delete namespace demo --ignore-not-found

info "Deleting EKS cluster '${CLUSTER_NAME}'..."
$AWSCLI eks delete-cluster --name "${CLUSTER_NAME}" --region "${REGION}" 2>/dev/null || true

info "Stopping LocalStack..."
if command -v lstk &>/dev/null; then
  lstk stop
else
  docker compose down -v
fi

info "Cleanup complete."
