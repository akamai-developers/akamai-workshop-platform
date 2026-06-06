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
    kubectl -n "${NAMESPACE}" delete statefulset vllm --ignore-not-found --timeout=120s || true
    kubectl -n "${NAMESPACE}" delete pvc --all --ignore-not-found --timeout=120s || true
    kubectl delete namespace "${NAMESPACE}" --ignore-not-found --timeout=120s || true
else
    printf '%b\n' "  ${DIM}No kubeconfig found; skipping K8s cleanup${RESET}"
fi

# Step 2: Terraform destroy
echo ""
printf '%b\n' "  ${BOLD}Step 2: Terraform destroy${RESET}"
cd "${TF_DIR}"
terraform destroy -auto-approve

# Local cleanup
rm -f "${KUBECONFIG_PATH}"
rm -rf "${INFRA_DIR}/manifests/generated"

echo ""
rule
printf '%b\n' "  ${GREEN}${BOLD}All resources destroyed.${RESET}"
rule
echo ""
