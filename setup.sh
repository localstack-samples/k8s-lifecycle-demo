#!/usr/bin/env bash
# setup.sh — Run this BEFORE the demo (ideally the night before).
# Creates a LocalStack EKS cluster, builds the app image, and loads it into the cluster.
set -euo pipefail

# ── Config ─────────────────────────────────────────────────────────────────────
CLUSTER_NAME="${CLUSTER_NAME:-lifecycle-demo}"
K8S_VERSION="${K8S_VERSION:-1.29}"
IMAGE_NAME="counter-app:latest"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Colors ─────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${GREEN}[setup] $*${NC}"; }
warn()    { echo -e "${YELLOW}[setup] $*${NC}"; }
heading() { echo -e "\n${BOLD}${CYAN}==> $*${NC}\n"; }

# ── 1. Prerequisite check ──────────────────────────────────────────────────────
heading "Checking prerequisites"
for cmd in docker kubectl aws localstack; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' not found. See README.md for installation instructions."
    exit 1
  fi
done
# awslocal is a thin wrapper; fall back to AWS CLI with endpoint override
AWSCLI="aws --endpoint-url=http://localhost:4566"
if command -v awslocal &>/dev/null; then
  AWSCLI="awslocal"
fi
info "All prerequisites found."

# ── 2. Start LocalStack ────────────────────────────────────────────────────────
heading "Starting LocalStack"
if docker ps --format '{{.Names}}' | grep -q "^localstack"; then
  warn "LocalStack container already running — skipping start."
else
  info "Starting LocalStack via Docker Compose..."
  docker compose -f "${SCRIPT_DIR}/docker-compose.yml" up -d
  info "Waiting for LocalStack to be ready..."
  until curl -sf http://localhost:4566/_localstack/health | grep -q '"eks": "running"' 2>/dev/null; do
    echo -n "."
    sleep 3
  done
  echo ""
fi
info "LocalStack is up."

# ── 3. Create VPC networking resources ────────────────────────────────────────
# LocalStack's EKS implementation actually calls DescribeSubnets, so we must
# create real (locally-emulated) VPC/subnet/SG resources before CreateCluster.
heading "Provisioning VPC networking for EKS"

VPC_ID=$($AWSCLI ec2 describe-vpcs --region "${REGION}" \
  --filters "Name=tag:Name,Values=eks-demo-vpc" \
  --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "None")

if [[ "${VPC_ID}" == "None" || -z "${VPC_ID}" ]]; then
  info "Creating VPC..."
  VPC_ID=$($AWSCLI ec2 create-vpc \
    --cidr-block 10.0.0.0/16 \
    --region "${REGION}" \
    --query 'Vpc.VpcId' --output text)
  $AWSCLI ec2 create-tags \
    --resources "${VPC_ID}" \
    --tags Key=Name,Value=eks-demo-vpc \
    --region "${REGION}"
  info "VPC: ${VPC_ID}"
else
  info "Reusing existing VPC: ${VPC_ID}"
fi

SUBNET_ID=$($AWSCLI ec2 describe-subnets --region "${REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=eks-demo-subnet" \
  --query 'Subnets[0].SubnetId' --output text 2>/dev/null || echo "None")

if [[ "${SUBNET_ID}" == "None" || -z "${SUBNET_ID}" ]]; then
  info "Creating subnet..."
  SUBNET_ID=$($AWSCLI ec2 create-subnet \
    --vpc-id "${VPC_ID}" \
    --cidr-block 10.0.1.0/24 \
    --region "${REGION}" \
    --query 'Subnet.SubnetId' --output text)
  $AWSCLI ec2 create-tags \
    --resources "${SUBNET_ID}" \
    --tags Key=Name,Value=eks-demo-subnet \
    --region "${REGION}"
  info "Subnet: ${SUBNET_ID}"
else
  info "Reusing existing subnet: ${SUBNET_ID}"
fi

SG_ID=$($AWSCLI ec2 describe-security-groups --region "${REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=eks-demo-sg" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")

if [[ "${SG_ID}" == "None" || -z "${SG_ID}" ]]; then
  info "Creating security group..."
  SG_ID=$($AWSCLI ec2 create-security-group \
    --group-name eks-demo-sg \
    --description "EKS demo security group" \
    --vpc-id "${VPC_ID}" \
    --region "${REGION}" \
    --query 'GroupId' --output text)
  info "Security group: ${SG_ID}"
else
  info "Reusing existing security group: ${SG_ID}"
fi

# IAM role — LocalStack doesn't validate the trust policy but the ARN must exist
ROLE_ARN=$($AWSCLI iam get-role --role-name eks-demo-role \
  --query 'Role.Arn' --output text 2>/dev/null || echo "")

if [[ -z "${ROLE_ARN}" ]]; then
  info "Creating IAM role for EKS..."
  ROLE_ARN=$($AWSCLI iam create-role \
    --role-name eks-demo-role \
    --assume-role-policy-document '{
      "Version":"2012-10-17",
      "Statement":[{
        "Effect":"Allow",
        "Principal":{"Service":"eks.amazonaws.com"},
        "Action":"sts:AssumeRole"
      }]
    }' \
    --query 'Role.Arn' --output text)
  info "IAM role: ${ROLE_ARN}"
else
  info "Reusing existing IAM role: ${ROLE_ARN}"
fi

# ── 4. Create EKS cluster ──────────────────────────────────────────────────────
heading "Creating EKS cluster: ${CLUSTER_NAME}"
if $AWSCLI eks describe-cluster --name "${CLUSTER_NAME}" --region "${REGION}" \
     --query 'cluster.status' --output text 2>/dev/null | grep -q ACTIVE; then
  warn "Cluster '${CLUSTER_NAME}' already exists — skipping create."
else
  info "Submitting CreateCluster to LocalStack EKS..."
  $AWSCLI eks create-cluster \
    --name "${CLUSTER_NAME}" \
    --kubernetes-version "${K8S_VERSION}" \
    --role-arn "${ROLE_ARN}" \
    --resources-vpc-config "subnetIds=${SUBNET_ID},securityGroupIds=${SG_ID}" \
    --region "${REGION}"

  info "Waiting for cluster to become ACTIVE..."
  until $AWSCLI eks describe-cluster --name "${CLUSTER_NAME}" --region "${REGION}" \
          --query 'cluster.status' --output text 2>/dev/null | grep -q ACTIVE; do
    echo -n "."
    sleep 5
  done
  echo ""
fi
info "Cluster '${CLUSTER_NAME}' is ACTIVE."

# ── 5. Configure kubectl ───────────────────────────────────────────────────────
heading "Configuring kubectl"
$AWSCLI eks update-kubeconfig \
  --name "${CLUSTER_NAME}" \
  --region "${REGION}" \
  --alias "${CLUSTER_NAME}"

kubectl config use-context "${CLUSTER_NAME}"
info "kubectl context set to '${CLUSTER_NAME}'."
kubectl cluster-info

# ── 6. Build the app image ─────────────────────────────────────────────────────
heading "Building app image: ${IMAGE_NAME}"
docker build -t "${IMAGE_NAME}" "${SCRIPT_DIR}/app"
info "Image built."

# ── 7. Load image into the cluster ────────────────────────────────────────────
# LocalStack EKS uses k3d under the hood.
heading "Loading image into cluster nodes"
if command -v k3d &>/dev/null; then
  info "Using k3d to import image..."
  k3d image import "${IMAGE_NAME}" --cluster "${CLUSTER_NAME}"
else
  warn "k3d not found — falling back to docker exec import."
  # Find the k3d server container LocalStack created
  K3D_CONTAINER=$(docker ps --filter "name=k3d-${CLUSTER_NAME}" --format "{{.Names}}" | head -1)
  if [[ -z "${K3D_CONTAINER}" ]]; then
    echo "ERROR: Could not find k3d container for cluster '${CLUSTER_NAME}'."
    echo "Install k3d (https://k3d.io) and re-run, or check 'docker ps'."
    exit 1
  fi
  info "Importing into container: ${K3D_CONTAINER}"
  docker save "${IMAGE_NAME}" \
    | docker exec -i "${K3D_CONTAINER}" ctr images import -
fi
info "Image '${IMAGE_NAME}' is available in the cluster."

# ── Done ───────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}Setup complete! You're ready to run the demo.${NC}"
echo ""
echo "  Run the demo:  ./demo.sh"
echo ""
