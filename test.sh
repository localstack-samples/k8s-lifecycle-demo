#!/usr/bin/env bash
# test.sh — Check the Deployment Lifecycle the demo walks through, on the
# LocalStack EKS cluster created by setup.sh:
# 1. the API server accepts the manifest
# 2. the Deployment creates a ReplicaSet and 2 Ready pods
# 3-4. each pod is scheduled to a node and its container is started
# 6. both pods are Service endpoints and requests through the Service reach both
# 7. a deleted pod is replaced and the replacement becomes Ready
set -euo pipefail

NAMESPACE="demo"
CLUSTER_NAME="${CLUSTER_NAME:-lifecycle-demo}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-180}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELECTOR="app=counter-app"

fail() {
  echo "Test failed: $*"
  exit 1
}

# Names of pods that are Ready and not being deleted
ready_pods() {
  kubectl get pods -n "${NAMESPACE}" -l "${SELECTOR}" -o json \
    | python3 -c '
import json, sys
for pod in json.load(sys.stdin)["items"]:
    if pod["metadata"].get("deletionTimestamp"):
        continue
    conditions = pod["status"].get("conditions", [])
    if any(c["type"] == "Ready" and c["status"] == "True" for c in conditions):
        print(pod["metadata"]["name"])
'
}

kubectl config use-context "${CLUSTER_NAME}" > /dev/null
kubectl delete namespace "${NAMESPACE}" --ignore-not-found --wait=true

# Step 1: API server
kubectl apply -f "${SCRIPT_DIR}/k8s/deployment.yaml"
kubectl get deployment counter-app -n "${NAMESPACE}" > /dev/null \
  || fail "the Deployment was not stored"
echo "PASS: the API server accepted the manifest"

# Steps 2 and 5: controllers create the ReplicaSet and pods, which become Ready
kubectl rollout status deployment/counter-app -n "${NAMESPACE}" --timeout="${TIMEOUT_SECONDS}s"
ready=$(kubectl get deployment counter-app -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}')
[[ "${ready}" == "2" ]] || fail "expected 2 Ready replicas, found '${ready}'"
replicasets=$(kubectl get replicaset -n "${NAMESPACE}" -l "${SELECTOR}" -o name | wc -l | tr -d ' ')
[[ "${replicasets}" -ge 1 ]] || fail "no ReplicaSet owns the pods"
echo "PASS: the Deployment created a ReplicaSet and 2 Ready pods"

# Steps 3 and 4: scheduler and kubelet
nodes=$(kubectl get pods -n "${NAMESPACE}" -l "${SELECTOR}" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}')
[[ $(echo "${nodes}" | grep -c .) == "2" ]] || fail "not every pod is assigned to a node: '${nodes}'"
for reason in Scheduled Started; do
  count=$(kubectl get events -n "${NAMESPACE}" --field-selector "reason=${reason}" -o name | wc -l | tr -d ' ')
  [[ "${count}" -ge 2 ]] || fail "expected 2 '${reason}' events, found ${count}"
done
echo "PASS: each pod was scheduled to a node ($(echo "${nodes}" | sort -u | paste -sd, -)) and its container started"

# Step 6: Service endpoints and traffic
endpoints=$(kubectl get endpoints counter-app -n "${NAMESPACE}" -o jsonpath='{.subsets[*].addresses[*].ip}' | wc -w | tr -d ' ')
[[ "${endpoints}" == "2" ]] || fail "expected 2 Service endpoints, found ${endpoints}"
echo "PASS: both pods are registered as Service endpoints"

pods=$(ready_pods)
exec_pod=$(echo "${pods}" | head -1)
# Each line: pod name and node name from the response
responses=$(kubectl exec "${exec_pod}" -n "${NAMESPACE}" -- python3 -c '
import json, urllib.request
for _ in range(30):
    body = json.loads(urllib.request.urlopen("http://counter-app.demo.svc.cluster.local/", timeout=5).read())
    print(body["pod"], body["node"])
')
seen=$(echo "${responses}" | awk '{print $1}' | sort -u)
for pod in ${pods}; do
  echo "${seen}" | grep -qx "${pod}" || fail "no request through the Service reached ${pod}; responses came from: ${seen}"
done
while read -r pod node; do
  expected_node=$(kubectl get pod "${pod}" -n "${NAMESPACE}" -o jsonpath='{.spec.nodeName}')
  [[ "${node}" == "${expected_node}" ]] || fail "${pod} reported node '${node}', expected '${expected_node}'"
done <<< "$(echo "${responses}" | sort -u)"
echo "PASS: requests through the Service reached both pods, which report their own pod and node names"

# Step 7: self-healing
victim=$(echo "${pods}" | head -1)
kubectl delete pod "${victim}" -n "${NAMESPACE}" --wait=false
waited=0
until current=$(ready_pods) \
    && [[ $(echo "${current}" | grep -c .) == "2" ]] \
    && ! echo "${current}" | grep -qx "${victim}"; do
  (( waited >= TIMEOUT_SECONDS )) && fail "no Ready replacement for ${victim} within ${TIMEOUT_SECONDS}s"
  sleep 2
  waited=$((waited + 2))
done
replacement=$(echo "${current}" | grep -vxF "$(echo "${pods}" | sed -n 2p)")
echo "PASS: deleted ${victim}; replacement ${replacement} became Ready after ${waited}s"

echo "Test passed: the Deployment went through every lifecycle step on LocalStack EKS"
