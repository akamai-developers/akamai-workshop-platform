#!/usr/bin/env bash
set -euo pipefail

# Phase-3 isolation proof for cluster_access=scoped. Two fences, both mandatory:
#
#   1. DATA PLANE — per-namespace NetworkPolicy. Positive control first (student A's
#      workspace reaches student B's vLLM pod with NO policy → SUCCEEDS, proving the
#      path works), then apply the scoped policies and prove the SAME probe is BLOCKED.
#   2. CONTROL PLANE — scoped kubeconfig. The student SA token is Forbidden for
#      `get nodes`, for kube-system, and for another student's namespace, but ALLOWED
#      in its own namespace.
#
# DEFERRED in the current environment (host disk full → kind API unwritable). Ready to
# run as-is once a kind+Cilium cluster (tests/kind-cluster.yaml) is healthy. Requires
# that tests/cilium-enforcement-check.sh has already proven the CNI enforces policy.
#
# Usage: tests/phase3-isolation-check.sh   (requires kubectl context kind-awp)

CTX="${KIND_CONTEXT:-kind-awp}"
K="kubectl --context ${CTX}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELM_DIR="${REPO_ROOT}/infra/helm"
A="workshop-s01"
B="workshop-s02"

pass() { echo "  OK: $*"; }
fail() { echo "  FAIL: $*" >&2; exit 1; }

cleanup() {
  $K delete namespace "${A}" "${B}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== Phase-3 scoped isolation check ==="

# Bare namespaces + SA/Role/RoleBinding from the scoped helm render (no NetworkPolicy
# yet, so we can establish the positive control before fencing the data plane).
helm template "${HELM_DIR}" --set cluster_access=scoped --set student_count=2 \
  --show-only templates/student-namespaces.yaml | $K apply -f - >/dev/null

# Target: a vLLM-labelled server in student B; client: a workspace-labelled pod in A.
$K -n "${B}" run vllm --image=nginx:alpine --labels=app=vllm --port=80 >/dev/null
$K -n "${B}" wait --for=condition=Ready pod/vllm --timeout=90s >/dev/null
TARGET_IP="$($K -n "${B}" get pod vllm -o jsonpath='{.status.podIP}')"

probe() {  # A's workspace pod curls B's vLLM by IP; 0 = reachable, 1 = blocked
  $K -n "${A}" run client --rm -i --restart=Never --image=curlimages/curl \
     --labels=app=workspace --command -- \
     curl -sS --max-time 5 "http://${TARGET_IP}" >/dev/null 2>&1
}

echo "[1/2] DATA PLANE"
if probe; then pass "positive control: A->B reachable with no policy"; else
  fail "A->B unreachable even before any policy (cluster/path broken)"; fi

# Now apply the per-namespace NetworkPolicies and re-probe.
helm template "${HELM_DIR}" --set cluster_access=scoped --set student_count=2 \
  --show-only templates/student-networkpolicy.yaml | $K apply -f - >/dev/null
sleep 3
if probe; then
  fail "A->B STILL reachable after scoped NetworkPolicy — isolation broken"
else
  pass "A->B blocked by per-namespace NetworkPolicy"
fi

echo "[2/2] CONTROL PLANE (scoped kubeconfig)"
TOKEN="$($K create token student -n "${A}" --duration=1h)"
SERVER="$($K config view --raw -o jsonpath="{.clusters[0].cluster.server}")"
KC="$(mktemp)"
trap 'rm -f "${KC}"; cleanup' EXIT
cat > "${KC}" <<EOF
apiVersion: v1
kind: Config
clusters: [{name: c, cluster: {server: ${SERVER}, insecure-skip-tls-verify: true}}]
users: [{name: u, user: {token: ${TOKEN}}}]
contexts: [{name: x, context: {cluster: c, user: u, namespace: ${A}}}]
current-context: x
EOF
KS="kubectl --kubeconfig ${KC}"

forbidden() {  # assert the command is Forbidden (non-zero)
  if $KS "$@" >/dev/null 2>&1; then fail "scoped SA could run: $*"; else pass "Forbidden: $*"; fi
}
forbidden get nodes
forbidden -n kube-system get pods
forbidden -n "${B}" get pods
if $KS -n "${A}" get pods >/dev/null 2>&1; then pass "own namespace ${A} allowed"; else fail "scoped SA cannot read its OWN namespace"; fi

echo "PHASE-3 ISOLATION OK"
