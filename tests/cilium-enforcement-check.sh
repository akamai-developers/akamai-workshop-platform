#!/usr/bin/env bash
set -euo pipefail

# Proves the kind cluster's CNI (Cilium) actually ENFORCES NetworkPolicy — an
# unenforced policy is silently decorative, which would make every Phase-3
# isolation test a false pass. Positive control first (A->B works with no policy),
# then apply default-deny and prove A->B is BLOCKED. Throwaway namespace; cleaned up.
#
# Usage: tests/cilium-enforcement-check.sh   (requires kubectl context kind-awp)

CTX="${KIND_CONTEXT:-kind-awp}"
NS="np-enforce-check"
K="kubectl --context ${CTX}"

cleanup() { $K delete namespace "${NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

$K delete namespace "${NS}" --ignore-not-found --wait >/dev/null 2>&1 || true
$K create namespace "${NS}" >/dev/null

$K -n "${NS}" run server --image=nginx:alpine --labels=app=server \
   --port=80 >/dev/null
$K -n "${NS}" expose pod server --port=80 >/dev/null
$K -n "${NS}" wait --for=condition=Ready pod/server --timeout=90s >/dev/null

probe() {  # returns 0 if client can reach server, 1 if blocked
  $K -n "${NS}" run client --rm -i --restart=Never --image=curlimages/curl \
     --command -- curl -sS --max-time 5 http://server >/dev/null 2>&1
}

echo "[1/2] positive control: A->B with no policy must SUCCEED"
if probe; then echo "  OK: reachable with no policy"; else
  echo "  FAIL: server unreachable even without a policy" >&2; exit 1; fi

cat <<EOF | $K -n "${NS}" apply -f - >/dev/null
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
spec:
  podSelector: {}
  policyTypes: [Ingress]
EOF
# Give the agent a moment to program the policy.
sleep 3

echo "[2/2] default-deny applied: A->B must be BLOCKED"
if probe; then
  echo "  FAIL: still reachable — CNI is NOT enforcing NetworkPolicy" >&2; exit 1
else
  echo "  OK: blocked — Cilium enforces NetworkPolicy"
fi

echo "ENFORCEMENT OK"
