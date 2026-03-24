#!/usr/bin/env bash
# demo.sh — Live walkthrough of the 7 steps of the Kubernetes Deployment Lifecycle.
#
# Prerequisites: run ./setup.sh first to create the LocalStack EKS cluster
#                and load the app image.
#
# Usage:
#   ./demo.sh          # interactive (press ENTER between steps)
#   AUTO=1 ./demo.sh   # fully automatic (uses STEP_DELAY seconds between steps)
set -euo pipefail

# ── Config ─────────────────────────────────────────────────────────────────────
NAMESPACE="demo"
CLUSTER_NAME="${CLUSTER_NAME:-lifecycle-demo}"
STEP_DELAY="${STEP_DELAY:-4}"   # seconds to wait in AUTO mode
AUTO="${AUTO:-0}"

# ── Colors & formatting ────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── Helper functions ───────────────────────────────────────────────────────────

banner() {
  local text="$1"
  local width=60
  local pad=$(( (width - ${#text}) / 2 ))
  echo ""
  echo -e "${CYAN}$(printf '═%.0s' $(seq 1 $width))${NC}"
  echo -e "${CYAN}║${NC}$(printf ' %.0s' $(seq 1 $pad))${BOLD}${text}${NC}$(printf ' %.0s' $(seq 1 $pad))${CYAN}║${NC}"
  echo -e "${CYAN}$(printf '═%.0s' $(seq 1 $width))${NC}"
  echo ""
}

step_header() {
  local num="$1"
  local title="$2"
  local subtitle="$3"
  echo ""
  echo -e "${BLUE}$(printf '─%.0s' $(seq 1 60))${NC}"
  echo -e "  ${BOLD}${YELLOW}STEP ${num}${NC}  ${BOLD}${title}${NC}"
  echo -e "  ${DIM}${subtitle}${NC}"
  echo -e "${BLUE}$(printf '─%.0s' $(seq 1 60))${NC}"
  echo ""
}

narrate() {
  echo -e "  ${GREEN}▶${NC}  $*"
}

cmd() {
  # Print the command in cyan, then execute it
  echo ""
  echo -e "  ${CYAN}\$${NC}  ${BOLD}$*${NC}"
  eval "$@"
  echo ""
}

pause() {
  if [[ "${AUTO}" == "1" ]]; then
    sleep "${STEP_DELAY}"
  else
    echo ""
    echo -e "  ${YELLOW}━━  Press ENTER to continue  ━━${NC}"
    read -r
  fi
}

watch_for() {
  # Run a command in background for N seconds, then kill it
  local seconds=$1; shift
  eval "$@" &
  local bg_pid=$!
  sleep "${seconds}"
  kill "${bg_pid}" 2>/dev/null || true
  wait "${bg_pid}" 2>/dev/null || true
}

wait_condition() {
  # Poll until kubectl condition is met (max 60s)
  local description="$1"; shift
  local max=60
  local elapsed=0
  echo -ne "  ${DIM}Waiting for ${description}...${NC}"
  until eval "$@" &>/dev/null; do
    echo -n "."
    sleep 2
    elapsed=$((elapsed + 2))
    if [[ $elapsed -ge $max ]]; then
      echo -e " ${RED}timeout${NC}"
      return 1
    fi
  done
  echo -e " ${GREEN}done${NC}"
}

cleanup_bg() {
  # Kill any background jobs we started
  jobs -p | xargs -r kill 2>/dev/null || true
}
trap cleanup_bg EXIT

# ── Preflight check ────────────────────────────────────────────────────────────
preflight() {
  banner "K8s Deployment Lifecycle — Live Demo"
  narrate "Checking kubectl context..."
  local ctx
  ctx=$(kubectl config current-context 2>/dev/null || echo "none")
  echo -e "     Context: ${BOLD}${ctx}${NC}"
  if [[ "${ctx}" != "${CLUSTER_NAME}" ]]; then
    echo -e "  ${YELLOW}WARNING: current context is '${ctx}', expected '${CLUSTER_NAME}'.${NC}"
    echo -e "  ${YELLOW}Run ./setup.sh first, or set CLUSTER_NAME to match your context.${NC}"
    echo -n "  Continue anyway? [y/N] "
    read -r answer
    [[ "${answer,,}" == "y" ]] || exit 1
  fi

  narrate "Cleaning up any previous demo run..."
  kubectl delete namespace "${NAMESPACE}" --ignore-not-found --wait=true 2>/dev/null || true
  narrate "Cluster is ready. Let's walk through all 7 steps of the Deployment Lifecycle."
  pause
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1 — kubectl apply → API Server ingestion
# ══════════════════════════════════════════════════════════════════════════════
step1_api_server() {
  step_header "1 / 7" "API Server — Manifest Submission" \
    "kubectl serialises the YAML and POSTs it to /apis/apps/v1/deployments"

  narrate "We run 'kubectl apply'. kubectl:"
  narrate "  1. Reads the local YAML and serialises it to JSON"
  narrate "  2. Sends a POST (or PATCH) to the API Server"
  narrate "  3. The API Server validates the object against its OpenAPI schema"
  narrate "  4. Persists the object in etcd — the cluster's source of truth"
  narrate "  5. Returns HTTP 201 Created"
  echo ""

  cmd "kubectl apply -f k8s/deployment.yaml"

  narrate "The Deployment, ReplicaSet objects, and Namespace now live in etcd."
  narrate "Nothing has been scheduled yet — the pods exist only as intent."
  pause
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2 — Controller Manager reconciliation
# ══════════════════════════════════════════════════════════════════════════════
step2_controllers() {
  step_header "2 / 7" "Controller Manager — Reconciliation Loop" \
    "Deployment Controller → ReplicaSet Controller → Pod objects created"

  narrate "The Controller Manager runs many control loops. Two fire immediately:"
  narrate ""
  narrate "  Deployment Controller:"
  narrate "    desired replicas=2, actual=0 → creates a ReplicaSet"
  narrate ""
  narrate "  ReplicaSet Controller:"
  narrate "    desired pods=2, actual=0 → creates 2 Pod objects in etcd"
  narrate "    (pods have no Node assigned yet — status is Pending)"
  echo ""

  narrate "Watching events as controllers act (5 s)..."
  cmd "kubectl get events -n ${NAMESPACE} --sort-by='.lastTimestamp' -w" &
  sleep 5
  cleanup_bg

  echo ""
  narrate "Check the objects that now exist:"
  cmd "kubectl get deployment,replicaset,pod -n ${NAMESPACE}"
  pause
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3 — Scheduler assignment
# ══════════════════════════════════════════════════════════════════════════════
step3_scheduler() {
  step_header "3 / 7" "Scheduler — Node Assignment" \
    "Watches for pods with .spec.nodeName == '' and assigns them to nodes"

  narrate "The kube-scheduler watches for unscheduled pods (nodeName is empty)."
  narrate "For each pod it runs two phases:"
  narrate "  Filtering  — eliminates nodes that don't satisfy constraints"
  narrate "               (resource requests, taints, affinity, etc.)"
  narrate "  Scoring    — ranks remaining nodes (LeastAllocated, etc.)"
  narrate "Then it writes the winning node name back to the Pod object in etcd."
  echo ""

  narrate "Pods are currently Pending — waiting for scheduler (10 s)..."
  watch_for 10 \
    "kubectl get pods -n ${NAMESPACE} -o wide -w"

  echo ""
  narrate "Node assignments after scheduling:"
  cmd "kubectl get pods -n ${NAMESPACE} -o wide"

  echo ""
  narrate "Scheduler events (grep for 'Scheduled'):"
  kubectl get events -n "${NAMESPACE}" --sort-by='.lastTimestamp' \
    | grep -i "scheduled" || echo "  (no Scheduled events yet — try again in a moment)"
  pause
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4 — Kubelet image pull & container start
# ══════════════════════════════════════════════════════════════════════════════
step4_kubelet() {
  step_header "4 / 7" "Kubelet — Image Pull & Container Start" \
    "Kubelet on each node watches for pods assigned to it, then calls the container runtime"

  narrate "Once the scheduler writes a nodeName, the kubelet on that node:"
  narrate "  1. Detects the new pod via its informer cache"
  narrate "  2. Calls the container runtime (containerd/CRI-O) to pull the image"
  narrate "  3. Creates the sandbox (pause container) and the app container"
  narrate "  4. Starts the container process"
  echo ""

  narrate "Image-pull events:"
  kubectl get events -n "${NAMESPACE}" --sort-by='.lastTimestamp' \
    | grep -iE "pulling|pulled|created|started" \
    || echo "  (events may not have arrived yet)"

  echo ""
  narrate "Full pod describe (first pod):"
  local first_pod
  first_pod=$(kubectl get pods -n "${NAMESPACE}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -n "${first_pod}" ]]; then
    cmd "kubectl describe pod ${first_pod} -n ${NAMESPACE}"
  fi
  pause
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5 — Pods transition Pending → Running
# ══════════════════════════════════════════════════════════════════════════════
step5_running() {
  step_header "5 / 7" "Pod Phase: Pending → Running" \
    "Container is up; readiness probe hasn't passed yet — pod is Running but not Ready"

  narrate "A pod's Phase field tracks coarse-grained lifecycle state:"
  narrate "  Pending  — scheduled but containers not yet started"
  narrate "  Running  — at least one container is running"
  narrate "  Succeeded/Failed — terminal states"
  narrate ""
  narrate "Running does NOT mean traffic is being sent to the pod."
  narrate "That gate is the Readiness Probe (Step 6)."
  echo ""

  narrate "Watching pod phases transition (15 s)..."
  watch_for 15 \
    "kubectl get pods -n ${NAMESPACE} -w"

  echo ""
  cmd "kubectl get pods -n ${NAMESPACE}"
  pause
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 6 — Readiness probe passes → pod becomes Ready
# ══════════════════════════════════════════════════════════════════════════════
step6_ready() {
  step_header "6 / 7" "Readiness Probe → Pod Ready → Service Endpoints" \
    "Kubelet runs GET /health; on success the pod is added to the Service's endpoint list"

  narrate "The kubelet calls GET /health every 5 s (periodSeconds)."
  narrate "After successThreshold=1 consecutive success:"
  narrate "  • Pod condition Ready=True"
  narrate "  • Endpoints controller adds the pod IP to the Service's Endpoints object"
  narrate "  • kube-proxy / eBPF programs update load-balancer rules"
  narrate "  → Traffic can now reach the pod"
  echo ""

  narrate "Waiting for all pods to be Ready..."
  wait_condition "all pods Ready" \
    kubectl wait pod \
      --for=condition=Ready \
      --all \
      -n "${NAMESPACE}" \
      --timeout=90s

  echo ""
  cmd "kubectl get pods -n ${NAMESPACE} -o wide"

  echo ""
  narrate "Service endpoints registered:"
  cmd "kubectl get endpoints counter-app -n ${NAMESPACE}"

  echo ""
  narrate "Hitting the service 4 times to show load-balancing across pods..."
  narrate "(running inside the cluster — the node IP is on the Docker bridge, not host-reachable)"
  # Pick any running pod to exec from; the Service DNS name load-balances
  # across all Ready pods, so responses will show different pod names.
  local exec_pod
  exec_pod=$(kubectl get pods -n "${NAMESPACE}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -z "${exec_pod}" ]]; then
    narrate "No running pod found to exec from — skipping curl demo."
  else
    local svc_url="http://counter-app.${NAMESPACE}.svc.cluster.local/"
    for i in 1 2 3 4; do
      echo -e "  ${CYAN}\$${NC}  ${BOLD}kubectl exec ${exec_pod} -n ${NAMESPACE} -- python3 -c \"...urllib ${svc_url}\"${NC}"
      kubectl exec "${exec_pod}" -n "${NAMESPACE}" -- \
        python3 -c "
import urllib.request, json
resp = urllib.request.urlopen('${svc_url}')
print(json.dumps(json.loads(resp.read()), indent=2))
" 2>/dev/null || echo "  (request failed)"
      sleep 1
    done
  fi
  pause
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 7 — Simulate node failure / pod rescheduling
# ══════════════════════════════════════════════════════════════════════════════
step7_rescheduling() {
  step_header "7 / 7" "Self-Healing — Pod Deletion & Rescheduling" \
    "ReplicaSet controller detects drift and creates a replacement pod immediately"

  narrate "We simulate a node failure by deleting one pod."
  narrate "The ReplicaSet controller sees actual=1, desired=2 and reconciles."
  narrate ""
  narrate "Watch carefully: the old pod Terminates while a brand-new pod appears"
  narrate "and races through Pending → Running → Ready."
  echo ""

  local victim
  victim=$(kubectl get pods -n "${NAMESPACE}" \
    -o jsonpath='{.items[0].metadata.name}')
  narrate "Selected pod to delete: ${BOLD}${victim}${NC}"
  echo ""

  # Start the watch in background
  kubectl get pods -n "${NAMESPACE}" -w &
  local watch_pid=$!

  # Delete the pod
  echo ""
  echo -e "  ${CYAN}\$${NC}  ${BOLD}kubectl delete pod ${victim} -n ${NAMESPACE}${NC}"
  kubectl delete pod "${victim}" -n "${NAMESPACE}"

  narrate "Pod deleted. Waiting 20 s for replacement to reach Ready..."
  sleep 20
  kill "${watch_pid}" 2>/dev/null || true
  wait "${watch_pid}" 2>/dev/null || true

  echo ""
  cmd "kubectl get pods -n ${NAMESPACE} -o wide"

  echo ""
  narrate "Events showing the full rescheduling sequence:"
  kubectl get events -n "${NAMESPACE}" --sort-by='.lastTimestamp' | tail -15

  echo ""
  narrate "Describe the new pod to see scheduler assignment + probe history:"
  local new_pod
  new_pod=$(kubectl get pods -n "${NAMESPACE}" \
    -o jsonpath='{.items[0].metadata.name}')
  cmd "kubectl describe pod ${new_pod} -n ${NAMESPACE}"
  pause
}

# ══════════════════════════════════════════════════════════════════════════════
# Wrap-up
# ══════════════════════════════════════════════════════════════════════════════
wrap_up() {
  banner "Demo Complete"
  echo -e "  ${BOLD}The 7 steps we just watched:${NC}"
  echo ""
  echo -e "  ${GREEN}1${NC}  API Server      — accepted the manifest, stored in etcd"
  echo -e "  ${GREEN}2${NC}  Controllers     — Deployment & ReplicaSet reconciliation loops"
  echo -e "  ${GREEN}3${NC}  Scheduler       — filtered + scored nodes, assigned pods"
  echo -e "  ${GREEN}4${NC}  Kubelet         — pulled the image, called the container runtime"
  echo -e "  ${GREEN}5${NC}  Pod phase       — Pending → Running"
  echo -e "  ${GREEN}6${NC}  Readiness probe — Running → Ready, traffic begins flowing"
  echo -e "  ${GREEN}7${NC}  Self-healing    — deleted pod replaced automatically"
  echo ""
  echo -e "  ${DIM}Cleanup: kubectl delete namespace ${NAMESPACE}${NC}"
  echo ""
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
  preflight
  step1_api_server
  step2_controllers
  step3_scheduler
  step4_kubelet
  step5_running
  step6_ready
  step7_rescheduling
  wrap_up
}

main "$@"
