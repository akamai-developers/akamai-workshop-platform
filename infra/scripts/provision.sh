#!/usr/bin/env bash
set -euo pipefail

# Provision the akamai-workshop-platform classroom on LKE.
# Idempotent — safe to run multiple times.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
KUBECONFIG_PATH="${INFRA_DIR}/kubeconfig.yaml"

# Parameterized: the wizard sets these; defaults match the reference 80-student plan.
NAMESPACE="${NAMESPACE:-workshop}"
DOMAIN="${DOMAIN:-}"   # "" → no-domain mode (sslip.io + self-signed TLS)
HELM_BIN="${HELM_BIN:-helm}"
HELM_VALUES="${HELM_VALUES:-${INFRA_DIR}/helm/values.yaml}"
# Rendered manifests go under the gitignored generated/ dir (may embed an HF token).
RENDERED="${INFRA_DIR}/manifests/generated/rendered.yaml"

echo "=== akamai-workshop-platform — Provisioning ==="
echo ""

# Step 1: Terraform — cluster + operators + DNS + ingress LB
echo "--- Step 1: Terraform (LKE + gpu-operator + ingress-nginx + cloud-firewall + DNS) ---"
cd "${INFRA_DIR}/terraform"

if [ ! -f terraform.tfvars ] && [ -z "${TF_VAR_token:-}" ]; then
    echo "ERROR: Set TF_VAR_token or create terraform/terraform.tfvars (see terraform.tfvars.example)"
    exit 1
fi

terraform init -upgrade
terraform apply -auto-approve

# Step 2: Kubeconfig
echo ""
echo "--- Step 2: Export kubeconfig ---"
terraform output -raw kubeconfig | base64 -d > "${KUBECONFIG_PATH}"
export KUBECONFIG="${KUBECONFIG_PATH}"
echo "Kubeconfig written to ${KUBECONFIG_PATH}"

LB_IP=$(terraform output -raw ingress_lb_ip)
BASE_HOST=$(terraform output -raw base_host)
export BASE_HOST
echo "Ingress LB: ${LB_IP}"
echo "Base host:  ${BASE_HOST}  (*.${BASE_HOST} → ${LB_IP})"

# Step 3: Wait for GPU operator to expose nvidia.com/gpu
echo ""
echo "--- Step 3: Wait for GPU operator to expose GPUs ---"
echo "    (gpu-operator installs drivers + device plugin; 3-5 min)"
for i in $(seq 1 60); do
    GPU_NODES=$(kubectl get nodes -o json | python3 -c "import sys,json; d=json.load(sys.stdin); print(sum(1 for n in d['items'] if int(n['status']['allocatable'].get('nvidia.com/gpu', '0')) > 0))" 2>/dev/null || echo "0")
    if [ "${GPU_NODES}" -ge 1 ]; then
        echo "  ✓ ${GPU_NODES} node(s) report nvidia.com/gpu"
        break
    fi
    echo "  …waiting (${i}/60) — GPU nodes ready: ${GPU_NODES}"
    sleep 15
done

if [ "${GPU_NODES:-0}" -lt 1 ]; then
    echo "ERROR: No nodes report nvidia.com/gpu after 15 min."
    echo "  kubectl -n gpu-operator get pods   # inspect operator pods"
    exit 1
fi

# Step 4: Render + apply the shared cluster resources (namespace, networkpolicy,
# vLLM service + statefulset, optional HF secret) from the Helm chart. Values come
# from $HELM_VALUES; namespace is forced to $NAMESPACE so scripts stay in sync.
echo ""
echo "--- Step 4: Render + apply base manifests (helm chart) ---"
cd "${INFRA_DIR}"
mkdir -p manifests/generated
"${HELM_BIN}" template awp helm -f "${HELM_VALUES}" --set namespace="${NAMESPACE}" > "${RENDERED}"
kubectl apply -f "${RENDERED}"

# Step 5: Wait for vLLM
echo ""
echo "--- Step 5: Waiting for vLLM pods to be ready ---"
echo "    (First start: 5-10 min while each replica downloads the model to its PVC)"
kubectl -n "${NAMESPACE}" rollout status statefulset/vllm --timeout=900s

# Step 6: Issue wildcard TLS cert. issue-cert.sh self-selects the mode from $DOMAIN:
#   empty  → self-signed wildcard for *.<base_host> (openssl, no lego/DNS)
#   set    → Let's Encrypt wildcard via lego + Linode DNS-01
echo ""
echo "--- Step 6: Issue wildcard TLS cert (${DOMAIN:+domain: $DOMAIN}${DOMAIN:-no-domain / self-signed}) ---"
if kubectl -n "${NAMESPACE}" get secret workshop-tls >/dev/null 2>&1; then
    echo "  ✓ workshop-tls already exists; skipping (re-issue with ./scripts/issue-cert.sh)"
else
    DOMAIN="${DOMAIN:-}" BASE_HOST="${BASE_HOST}" NAMESPACE="${NAMESPACE}" \
        "${SCRIPT_DIR}/issue-cert.sh" || echo "  ! cert issuance failed; re-run ./scripts/issue-cert.sh"
fi

echo ""
echo "=== Base cluster ready! ==="
echo ""
echo "Next steps (workspaces use the stock code-server image + startup.sh ConfigMap;"
echo "no image build needed — building one is the optional ./scripts/build-workspace-image.sh):"
echo "  1. ./scripts/generate-pods.sh -n ${STUDENT_COUNT:-80} --host ${BASE_HOST}"
echo "  2. kubectl apply -f manifests/generated/"
echo "  3. ./scripts/health-check.sh"
echo "  4. ./scripts/capacity-test.sh                  # measure students-per-replica"
echo ""
echo "KUBECONFIG=${KUBECONFIG_PATH}"
