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

# Detect multi-model from the helm values file.
MULTI_MODEL=0
if grep -q "^multi_model: true" "${HELM_VALUES}" 2>/dev/null; then
    MULTI_MODEL=1
fi

# Detect the inference mode + student count. In dedicated-vllm mode each student
# runs their OWN vLLM Deployment (named 'vllm') in their own namespace
# (<namespace>-sNN), so the readiness wait targets per-student Deployments, not the
# shared StatefulSet.
INFERENCE="$(grep -E '^inference:' "${HELM_VALUES}" 2>/dev/null | head -1 | sed -E 's/^inference:[[:space:]]*//; s/[[:space:]#].*$//')"
INFERENCE="${INFERENCE:-shared-vllm}"
STUDENT_COUNT="$(grep -E '^student_count:' "${HELM_VALUES}" 2>/dev/null | head -1 | sed -E 's/[^0-9]//g')"
STUDENT_COUNT="${STUDENT_COUNT:-1}"

# Detect GPU sharing (time-slicing). When 'timeslicing', Step 3.5 patches the
# gpu-operator ClusterPolicy so each physical GPU advertises N logical GPUs — what
# lets a student run two vLLMs on one card. Default 'none' skips that step entirely.
GPU_SHARING="$(grep -E '^gpu_sharing:' "${HELM_VALUES}" 2>/dev/null | head -1 | sed -E 's/^gpu_sharing:[[:space:]]*//; s/[[:space:]#].*$//')"
GPU_SHARING="${GPU_SHARING:-none}"
GPU_TS_REPLICAS="$(grep -E '^gpu_timeslicing_replicas:' "${HELM_VALUES}" 2>/dev/null | head -1 | sed -E 's/[^0-9]//g')"
GPU_TS_REPLICAS="${GPU_TS_REPLICAS:-2}"

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

# If the caller didn't pass DOMAIN (e.g. a direct ./scripts/provision.sh re-run
# instead of going through deploy.sh), recover it from terraform.tfvars —
# otherwise Step 6 silently issues a self-signed cert for a deployment that has
# a real domain, and the existing-secret check hides that on every later run.
if [[ -z "${DOMAIN}" && -f terraform.tfvars ]]; then
    DOMAIN="$(grep -E '^[[:space:]]*domain[[:space:]]*=' terraform.tfvars 2>/dev/null \
        | head -1 | sed -nE 's/.*=[[:space:]]*"([^"]+)".*/\1/p' || true)"
fi

# Pre-clean stale DNS records before apply. When Terraform state was lost in a
# previous run, old A records linger and stack up (Linode allows duplicates).
_DOMAIN="${DOMAIN:-}"
_PREFIX="${SUBDOMAIN_PREFIX:-$(grep -E '^[[:space:]]*subdomain_prefix[[:space:]]*=' terraform.tfvars 2>/dev/null \
    | head -1 | sed -nE 's/.*=[[:space:]]*"([^"]+)".*/\1/p' || true)}"
_PREFIX="${_PREFIX:-workshop}"
# Pick the first candidate token the API accepts for Domains — a stale
# LINODE_TOKEN in a shell profile must not 401 the pre-clean into a silent
# no-op, or duplicate A records stack up exactly as described above.
_TOKEN=""
for _CAND in "${TF_VAR_token:-}" "${LINODE_TOKEN:-}"; do
    [[ -n "$_CAND" ]] || continue
    if [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
            -H "Authorization: Bearer ${_CAND}" \
            https://api.linode.com/v4/domains || true)" == "200" ]]; then
        _TOKEN="$_CAND"
        break
    fi
done

if [[ -n "$_DOMAIN" && -z "$_TOKEN" ]]; then
    echo "  WARN: no token the Linode API accepts for Domains — skipping DNS pre-clean."
fi

if [[ -n "$_DOMAIN" && -n "$_TOKEN" ]]; then
    python3 - "$_TOKEN" "$_DOMAIN" "$_PREFIX" <<'PY' || true
import json, sys, urllib.request, urllib.error
token, domain, prefix = sys.argv[1], sys.argv[2], sys.argv[3]
headers = {"Authorization": f"Bearer {token}"}
try:
    req = urllib.request.Request("https://api.linode.com/v4/domains", headers=headers)
    with urllib.request.urlopen(req, timeout=15) as r:
        domains = json.load(r).get("data", [])
    domain_id = next((d["id"] for d in domains if d["domain"] == domain), None)
    if not domain_id:
        sys.exit(0)
    req = urllib.request.Request(
        f"https://api.linode.com/v4/domains/{domain_id}/records?page_size=500",
        headers=headers)
    with urllib.request.urlopen(req, timeout=15) as r:
        records = json.load(r).get("data", [])
    targets = [prefix, f"*.{prefix}"]
    stale = [r for r in records if r.get("name") in targets and r.get("record_type") == "A"]
    for rec in stale:
        try:
            dreq = urllib.request.Request(
                f"https://api.linode.com/v4/domains/{domain_id}/records/{rec['id']}",
                headers=headers, method="DELETE")
            urllib.request.urlopen(dreq, timeout=15)
            print(f"  Cleaned stale DNS: {rec['name']} → {rec['target']}")
        except Exception:
            pass
except Exception:
    pass
PY
fi

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
if [ "${MULTI_MODEL}" -eq 1 ]; then
    # Multi-model: wait for GPU nodes across all pool labels.
    GPU_POOL_LABELS=$(python3 -c "
import re, sys
for raw in open('${HELM_VALUES}'):
    line = raw.split('#',1)[0].rstrip()
    m = re.match(r'^\s+gpu_pool_label:\s*\"?([^\"]+)\"?', line)
    if m: print(m.group(1))
" 2>/dev/null)
    REQUIRED_POOLS=$(echo "$GPU_POOL_LABELS" | wc -l | tr -d ' ')
    echo "    Waiting for ${REQUIRED_POOLS} GPU pool(s): ${GPU_POOL_LABELS//$'\n'/, }"
fi

REQUIRED_GPU_NODES=1
if [ "${MULTI_MODEL}" -eq 1 ]; then
    REQUIRED_GPU_NODES="${REQUIRED_POOLS}"
fi

for i in $(seq 1 60); do
    GPU_NODES=$(kubectl get nodes -o json | python3 -c "import sys,json; d=json.load(sys.stdin); print(sum(1 for n in d['items'] if int(n['status']['allocatable'].get('nvidia.com/gpu', '0')) > 0))" 2>/dev/null || echo "0")
    if [ "${GPU_NODES}" -ge "${REQUIRED_GPU_NODES}" ]; then
        echo "  ✓ ${GPU_NODES} node(s) report nvidia.com/gpu (need ${REQUIRED_GPU_NODES})"
        break
    fi
    echo "  …waiting (${i}/60) — GPU nodes ready: ${GPU_NODES}/${REQUIRED_GPU_NODES}"
    sleep 15
done

if [ "${GPU_NODES:-0}" -lt "${REQUIRED_GPU_NODES}" ]; then
    echo "ERROR: Only ${GPU_NODES}/${REQUIRED_GPU_NODES} nodes report nvidia.com/gpu after 15 min."
    echo "  kubectl -n gpu-operator get pods   # inspect operator pods"
    exit 1
fi

# Step 3.5: Enable NVIDIA time-slicing (gpu_sharing=timeslicing only).
# By default each pod gets an exclusive GPU; time-slicing makes the device plugin
# advertise N logical GPUs per card so a student can run two vLLMs on one GPU.
# We apply this AFTER the operator is up by patching its ClusterPolicy — the terraform
# gpu-operator install is untouched, so gpu_sharing=none clusters are unchanged.
# Total allocatable nvidia.com/gpu across all nodes. Used to verify time-slicing.
gpu_total() {
    kubectl get nodes -o json | python3 -c "import sys,json; d=json.load(sys.stdin); print(sum(int(n['status']['allocatable'].get('nvidia.com/gpu','0')) for n in d['items']))" 2>/dev/null || echo "0"
}

if [ "${GPU_SHARING}" = "timeslicing" ]; then
    echo ""
    echo "--- Step 3.5: Enable GPU time-slicing (${GPU_TS_REPLICAS} logical GPUs/card) ---"
    # Baseline = physical GPUs advertised cluster-wide BEFORE slicing. After slicing,
    # every card advertises ${GPU_TS_REPLICAS}×, so the cluster total must rise to
    # PRE × replicas. Checking the TOTAL (not a per-node ">= N") is correct whether a
    # node has 1 or 4 physical GPUs, and can't false-pass on the pre-rollout device
    # plugin: the total only reaches the target once the new plugin actually rolls.
    PRE_GPU_TOTAL="$(gpu_total)"
    TARGET_GPU_TOTAL=$(( PRE_GPU_TOTAL * GPU_TS_REPLICAS ))
    kubectl apply -f - <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: time-slicing-config
  namespace: gpu-operator
data:
  any: |-
    version: v1
    flags:
      migStrategy: none
    sharing:
      timeSlicing:
        resources:
        - name: nvidia.com/gpu
          replicas: ${GPU_TS_REPLICAS}
YAML
    CP="$(kubectl get clusterpolicy -o name 2>/dev/null | head -1)"
    if [ -z "${CP}" ]; then
        echo "ERROR: no gpu-operator ClusterPolicy found; cannot enable time-slicing."
        exit 1
    fi
    kubectl patch "${CP}" --type merge \
        -p '{"spec":{"devicePlugin":{"config":{"name":"time-slicing-config","default":"any"}}}}'
    echo "    Patched ${CP} (cluster had ${PRE_GPU_TOTAL} GPUs; expect ${TARGET_GPU_TOTAL} after slicing)."
    echo "    Waiting for the device plugin to roll and re-advertise..."
    for i in $(seq 1 40); do
        CUR_GPU_TOTAL="$(gpu_total)"
        if [ "${CUR_GPU_TOTAL}" -ge "${TARGET_GPU_TOTAL}" ] && [ "${TARGET_GPU_TOTAL}" -gt 0 ]; then
            echo "  ✓ cluster now advertises ${CUR_GPU_TOTAL} nvidia.com/gpu (${GPU_TS_REPLICAS}× of ${PRE_GPU_TOTAL})"
            break
        fi
        echo "  …waiting (${i}/40) — nvidia.com/gpu: ${CUR_GPU_TOTAL}/${TARGET_GPU_TOTAL}"
        sleep 15
    done
    if [ "${CUR_GPU_TOTAL:-0}" -lt "${TARGET_GPU_TOTAL}" ]; then
        echo "ERROR: time-slicing did not take effect (cluster advertises ${CUR_GPU_TOTAL:-0}/${TARGET_GPU_TOTAL} nvidia.com/gpu) after 10 min."
        echo "  kubectl describe ${CP}                       # check devicePlugin.config"
        echo "  kubectl -n gpu-operator get pods             # device-plugin/gfd restart"
        exit 1
    fi
fi

# Step 4: Render + apply the shared cluster resources (namespace, networkpolicy,
# vLLM service + statefulset, optional HF secret) from the Helm chart. Values come
# from $HELM_VALUES; namespace is forced to $NAMESPACE so scripts stay in sync.
echo ""
echo "--- Step 4: Render + apply base manifests (helm chart) ---"
cd "${INFRA_DIR}"
mkdir -p manifests/generated

# Multi-model: install Gateway API CRDs + agentgateway before rendering the chart.
if [ "${MULTI_MODEL}" -eq 1 ]; then
    echo "  Installing Gateway API CRDs..."
    kubectl apply --server-side --force-conflicts \
        -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.0/standard-install.yaml || true
    echo "  Installing agentgateway CRDs..."
    "${HELM_BIN}" upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
        --create-namespace --namespace agentgateway-system --version v1.2.1 \
        --set controller.image.pullPolicy=Always || true
    echo "  Installing agentgateway controller..."
    "${HELM_BIN}" upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
        --namespace agentgateway-system --version v1.2.1 \
        --set controller.image.pullPolicy=Always \
        --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true --wait || true
fi

"${HELM_BIN}" template awp helm -f "${HELM_VALUES}" --set namespace="${NAMESPACE}" > "${RENDERED}"
kubectl apply -f "${RENDERED}"

# Step 5: Wait for vLLM
echo ""
echo "--- Step 5: Waiting for vLLM pods to be ready ---"
echo "    (First start: 5-10 min while each replica downloads the model to its PVC)"
if [ "${INFERENCE}" = "dedicated-vllm" ]; then
    # Per-student dedicated vLLM: one Deployment named 'vllm' in each student
    # namespace (<namespace>-sNN), created by generate-pods.sh in scoped mode.
    for i in $(seq 1 "${STUDENT_COUNT}"); do
        SNS="${NAMESPACE}-s$(printf '%02d' "$i")"
        echo "  Waiting for vllm in ${SNS}..."
        # 1800s matches the Deployment progressDeadlineSeconds (cold first-start download).
        # On failure, dump diagnostics BEFORE returning so a torn-down cluster is still debuggable.
        if ! kubectl -n "${SNS}" rollout status deployment/vllm --timeout=1800s; then
            echo "  vLLM in ${SNS} did not become ready — diagnostics:" >&2
            kubectl -n "${SNS}" get pods -o wide 2>&1 | sed 's/^/    /' || true
            kubectl -n "${SNS}" describe deployment/vllm 2>&1 | tail -25 | sed 's/^/    /' || true
            kubectl -n "${SNS}" logs deploy/vllm --tail=60 2>&1 | sed 's/^/    /' || true
            kubectl -n "${SNS}" get events --sort-by=.lastTimestamp 2>&1 | tail -20 | sed 's/^/    /' || true
            exit 1
        fi
    done
elif [ "${MULTI_MODEL}" -eq 0 ]; then
    kubectl -n "${NAMESPACE}" rollout status statefulset/vllm --timeout=900s
else
    # Wait for each per-model vLLM StatefulSet.
    for slug in $(python3 -c "
import re
for raw in open('${HELM_VALUES}'):
    line = raw.split('#',1)[0].rstrip()
    m = re.match(r'^\s+slug:\s*\"?([^\"]+)\"?', line)
    if m: print(m.group(1))
" 2>/dev/null); do
        echo "  Waiting for vllm-${slug}..."
        kubectl -n "${NAMESPACE}" rollout status "statefulset/vllm-${slug}" --timeout=900s
    done
    # Wait for agentgateway.
    echo "  Waiting for agentgateway..."
    kubectl -n "${NAMESPACE}" wait --for=condition=Programmed "gateway/agentgateway-proxy" --timeout=300s 2>/dev/null \
        || echo "  (agentgateway readiness check skipped — Gateway CRD may not support condition)"
fi

# Step 6: Issue wildcard TLS cert. issue-cert.sh self-selects the mode from $DOMAIN:
#   empty  → self-signed wildcard for *.<base_host> (openssl, no lego/DNS)
#   set    → Let's Encrypt wildcard via lego + Linode DNS-01
echo ""
echo "--- Step 6: Issue wildcard TLS cert (${DOMAIN:+domain: $DOMAIN}${DOMAIN:-no-domain / self-signed}) ---"
if kubectl -n "${NAMESPACE}" get secret workshop-tls >/dev/null 2>&1; then
    echo "  ✓ workshop-tls already exists; skipping (re-issue with ./scripts/issue-cert.sh)"
elif DOMAIN="${DOMAIN:-}" SUBDOMAIN_PREFIX="${_PREFIX}" EMAIL="${CERT_EMAIL:-}" \
        BASE_HOST="${BASE_HOST}" NAMESPACE="${NAMESPACE}" \
        "${SCRIPT_DIR}/issue-cert.sh"; then
    echo "  ✓ workshop-tls issued"
else
    # Non-fatal: the classroom still works, but TLS is NOT secured (nginx serves a
    # self-signed fallback). Make this LOUD — a swallowed one-liner here is how a
    # whole classroom shipped with browsers showing "not secure".
    cat <<EOF

  ############################################################################
  ! TLS CERT ISSUANCE FAILED. The classroom is usable, but every workshop URL
  ! will show "not secure" until you issue a real cert (nginx is serving its
  ! self-signed fallback because the 'workshop-tls' secret was not created).
  !
  ! Most common cause: the Linode token is expired or lacks 'Domains: Read/Write'
  ! scope (required for the Let's Encrypt DNS-01 challenge).
  !
  ! Fix — supply a valid Domains-scoped token, then re-run (idempotent):
  !     cd ${INFRA_DIR} && LINODE_TOKEN=<token with Domains:R/W> ${DOMAIN:+DOMAIN=${DOMAIN} SUBDOMAIN_PREFIX=${_PREFIX} }NAMESPACE=${NAMESPACE} ./scripts/issue-cert.sh
  ############################################################################
EOF
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
