#!/usr/bin/env bash
set -euo pipefail

# Tear down all workshop infrastructure. Destructive.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
KUBECONFIG_PATH="${INFRA_DIR}/kubeconfig.yaml"
TF_DIR="${INFRA_DIR}/terraform"
NAMESPACE="${NAMESPACE:-workshop}"

# Headless mode for the wizard / e2e smoke test: --yes / -y on the command line,
# or AWP_ASSUME_YES=1 / FORCE=1 in the environment, skips the interactive prompt.
ASSUME_YES="${AWP_ASSUME_YES:-${FORCE:-0}}"
for arg in "$@"; do
    case "$arg" in
        -y|--yes) ASSUME_YES=1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Formatting (matches deploy.sh)
# ---------------------------------------------------------------------------
if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]] && [[ -z "${NO_COLOR:-}" ]]; then
    BOLD=$'\033[1m'  DIM=$'\033[2m'  RESET=$'\033[0m'
    GREEN=$'\033[32m'  YELLOW=$'\033[33m'  RED=$'\033[31m'
else
    BOLD=""  DIM=""  RESET=""
    GREEN=""  YELLOW=""  RED=""
fi

rule() { printf '%b\n' "  ${DIM}────────────────────────────────────────────────────────────${RESET}"; }

# ---------------------------------------------------------------------------
# Identify what we're about to destroy
# ---------------------------------------------------------------------------
CLUSTER_LABEL=""
CLUSTER_REGION=""
CLUSTER_NODES=""

if [[ -f "${TF_DIR}/terraform.tfvars" ]]; then
    CLUSTER_LABEL="$(grep -E '^\s*label\s*=' "${TF_DIR}/terraform.tfvars" 2>/dev/null \
        | head -1 | sed 's/.*=\s*"\(.*\)"/\1/')"
    CLUSTER_REGION="$(grep -E '^\s*region\s*=' "${TF_DIR}/terraform.tfvars" 2>/dev/null \
        | head -1 | sed 's/.*=\s*"\(.*\)"/\1/')"
fi

if [[ -f "${KUBECONFIG_PATH}" ]]; then
    CLUSTER_NODES="$(KUBECONFIG="${KUBECONFIG_PATH}" kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
fi

echo ""
rule
printf '%b\n' "  ${RED}${BOLD}Teardown${RESET}"
rule
echo ""

if [[ -n "$CLUSTER_LABEL" ]]; then
    printf "  ${DIM}%-14s${RESET} %s\n" "Cluster:"  "$CLUSTER_LABEL"
    [[ -n "$CLUSTER_REGION" ]] && printf "  ${DIM}%-14s${RESET} %s\n" "Region:" "$CLUSTER_REGION"
    [[ -n "$CLUSTER_NODES" && "$CLUSTER_NODES" != "0" ]] && \
        printf "  ${DIM}%-14s${RESET} %s\n" "Nodes:" "$CLUSTER_NODES"
    echo ""
else
    printf '%b\n' "  ${DIM}(could not read cluster details from terraform.tfvars)${RESET}"
    echo ""
fi

printf '%b\n' "  ${YELLOW}This will destroy ALL workshop infrastructure, including PVCs.${RESET}"
echo ""

if [ "${ASSUME_YES}" != "1" ]; then
    printf '%b' "  ${BOLD}Continue?${RESET} ${DIM}(yes/no)${RESET} "
    read -r confirm
    if [ "$confirm" != "yes" ]; then
        printf '%b\n' "  ${DIM}Aborted.${RESET}"
        exit 0
    fi
else
    printf '%b\n' "  ${DIM}(--yes) proceeding without prompt.${RESET}"
fi

# Step 1: K8s cleanup (best-effort)
if [ -f "${KUBECONFIG_PATH}" ]; then
    export KUBECONFIG="${KUBECONFIG_PATH}"

    echo ""
    printf '%b\n' "  ${BOLD}Step 1: Delete Kubernetes resources${RESET}"
    # Delete all vLLM statefulsets (single-model: "vllm", multi-model: "vllm-<slug>").
    kubectl -n "${NAMESPACE}" delete statefulset -l app=vllm --ignore-not-found --timeout=120s || true
    # Delete agentgateway resources if they exist (multi-model).
    kubectl -n "${NAMESPACE}" delete deployment agentgateway --ignore-not-found --timeout=60s 2>/dev/null || true
    kubectl -n "${NAMESPACE}" delete gateway agentgateway-proxy --ignore-not-found 2>/dev/null || true
    kubectl -n "${NAMESPACE}" delete httproute vllm-routing --ignore-not-found 2>/dev/null || true
    kubectl -n "${NAMESPACE}" delete pvc --all --ignore-not-found --timeout=120s || true
    kubectl delete namespace "${NAMESPACE}" --ignore-not-found --timeout=120s || true
else
    printf '%b\n' "  ${DIM}No kubeconfig found; skipping K8s cleanup${RESET}"
fi

# Step 2: Terraform destroy
echo ""
printf '%b\n' "  ${BOLD}Step 2: Terraform destroy${RESET}"
cd "${TF_DIR}"
terraform destroy -auto-approve || true

# Step 3: Clean up stale DNS records (survives lost Terraform state).
# When Terraform state is wiped, the DNS records from previous deploys remain
# and stack up on the next deploy. This step removes them via the Linode API.
_TOKEN="${TF_VAR_token:-${LINODE_TOKEN:-}}"
_DOMAIN=""
_PREFIX=""
if [[ -f "${TF_DIR}/terraform.tfvars" ]]; then
    _DOMAIN="$(grep -E '^\s*domain\s*=' "${TF_DIR}/terraform.tfvars" 2>/dev/null \
        | head -1 | sed 's/.*=\s*"\(.*\)"/\1/')"
    _PREFIX="$(grep -E '^\s*subdomain_prefix\s*=' "${TF_DIR}/terraform.tfvars" 2>/dev/null \
        | head -1 | sed 's/.*=\s*"\(.*\)"/\1/')"
fi
_PREFIX="${_PREFIX:-workshop}"

if [[ -n "$_TOKEN" && -n "$_DOMAIN" ]]; then
    echo ""
    printf '%b\n' "  ${BOLD}Step 3: Clean up DNS records${RESET}"
    python3 - "$_TOKEN" "$_DOMAIN" "$_PREFIX" <<'PY'
import json, sys, urllib.request, urllib.error
token, domain, prefix = sys.argv[1], sys.argv[2], sys.argv[3]
headers = {"Authorization": f"Bearer {token}"}
try:
    req = urllib.request.Request(f"https://api.linode.com/v4/domains", headers=headers)
    with urllib.request.urlopen(req, timeout=15) as r:
        domains = json.load(r).get("data", [])
    domain_id = next((d["id"] for d in domains if d["domain"] == domain), None)
    if not domain_id:
        print(f"  Domain '{domain}' not found; skipping DNS cleanup")
        sys.exit(0)
    req = urllib.request.Request(
        f"https://api.linode.com/v4/domains/{domain_id}/records?page_size=500",
        headers=headers)
    with urllib.request.urlopen(req, timeout=15) as r:
        records = json.load(r).get("data", [])
    targets = [prefix, f"*.{prefix}"]
    stale = [r for r in records if r.get("name") in targets and r.get("record_type") == "A"]
    if not stale:
        print(f"  No workshop DNS records to clean up")
    for rec in stale:
        try:
            dreq = urllib.request.Request(
                f"https://api.linode.com/v4/domains/{domain_id}/records/{rec['id']}",
                headers=headers, method="DELETE")
            urllib.request.urlopen(dreq, timeout=15)
            print(f"  Deleted {rec['name']} → {rec['target']}")
        except Exception as e:
            print(f"  WARN: failed to delete record {rec['id']}: {e}")
except Exception as e:
    print(f"  WARN: DNS cleanup failed: {e}")
PY
else
    printf '%b\n' "  ${DIM}No domain in tfvars or no token; skipping DNS cleanup${RESET}"
fi

# Local cleanup
rm -f "${KUBECONFIG_PATH}"
rm -rf "${INFRA_DIR}/manifests/generated"

echo ""
rule
printf '%b\n' "  ${GREEN}${BOLD}All resources destroyed.${RESET}"
rule
echo ""
