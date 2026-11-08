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
    CLUSTER_LABEL="$(grep -E '^[[:space:]]*label[[:space:]]*=' "${TF_DIR}/terraform.tfvars" 2>/dev/null \
        | head -1 | sed -nE 's/.*=[[:space:]]*"([^"]*)".*/\1/p' || true)"
    CLUSTER_REGION="$(grep -E '^[[:space:]]*region[[:space:]]*=' "${TF_DIR}/terraform.tfvars" 2>/dev/null \
        | head -1 | sed -nE 's/.*=[[:space:]]*"([^"]*)".*/\1/p' || true)"
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

# ---------------------------------------------------------------------------
# Token. `terraform destroy` reads $TF_VAR_token and nothing else. deploy.sh only
# exports it on the deploy path, so `./deploy.sh teardown` with just $LINODE_TOKEN in
# the shell stopped at Terraform's "No value for required variable" prompt and left
# the cluster up (2026-11-08 rehearsal). Resolve it here the way deploy.sh does:
# the first candidate the API accepts. No usable token: stop before touching anything.
# ---------------------------------------------------------------------------
_TOKEN_PICKED=""
for _CAND_SRC in TF_VAR_token LINODE_TOKEN; do
    _CAND="${!_CAND_SRC:-}"
    [[ -n "$_CAND" ]] || continue
    _HTTP="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
        -H "Authorization: Bearer ${_CAND}" https://api.linode.com/v4/profile || true)"
    case "$_HTTP" in
        200)     _TOKEN_PICKED="$_CAND"
                 printf '%b\n' "  ${DIM}Linode token valid (from \$${_CAND_SRC}).${RESET}"; break ;;
        401|403) printf '%b\n' "  ${YELLOW}token from \$${_CAND_SRC} rejected (HTTP ${_HTTP}); trying next source.${RESET}" ;;
        *)       _TOKEN_PICKED="$_CAND"
                 printf '%b\n' "  ${YELLOW}could not validate \$${_CAND_SRC} (HTTP '${_HTTP}'); continuing with it.${RESET}"; break ;;
    esac
done
if [[ -z "$_TOKEN_PICKED" ]]; then
    printf '%b\n' "  ${RED}ERROR: no usable Linode token in \$TF_VAR_token or \$LINODE_TOKEN. Nothing destroyed.${RESET}" >&2
    exit 1
fi
export TF_VAR_token="$_TOKEN_PICKED"

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
    # cluster_access=scoped: every student namespace (label awp-student=true) holds its
    # own model-cache PVC. Deleting the LKE cluster does NOT delete the block-storage
    # volumes behind PVCs, so delete those namespaces here (pods, then PVCs) and wait for
    # the CSI driver to release the volumes before terraform destroys the cluster. Skipping
    # this orphaned 89 unattached 50 GB volumes after the September 2026 classes.
    _STUDENT_NS="$(kubectl get namespaces -l awp-student=true -o name 2>/dev/null | sed 's|^namespace/||' | tr '\n' ' ' || true)"
    if [[ -n "${_STUDENT_NS// /}" ]]; then
        echo "  deleting $(wc -w <<<"${_STUDENT_NS}" | tr -d ' ') student namespace(s) and their PVCs..."
        for _ns in ${_STUDENT_NS}; do
            kubectl -n "${_ns}" delete pvc --all --ignore-not-found --wait=false >/dev/null 2>&1 || true
        done
        # shellcheck disable=SC2086
        kubectl delete namespace ${_STUDENT_NS} --ignore-not-found --wait=false >/dev/null 2>&1 || true
    fi
    kubectl -n "${NAMESPACE}" delete pvc --all --ignore-not-found --timeout=120s || true
    kubectl delete namespace "${NAMESPACE}" --ignore-not-found --timeout=120s || true
    # Wait (up to 10 min) for every PersistentVolume to be released and deleted, so the
    # Linode CSI controller finishes deleting the backing volumes before the cluster goes.
    for _i in $(seq 1 60); do
        _PVS="$(kubectl get pv --no-headers 2>/dev/null | wc -l | tr -d ' ')"
        [[ "${_PVS}" == "0" ]] && break
        [[ $((_i % 6)) -eq 0 ]] && echo "  waiting for ${_PVS} PersistentVolume(s) to be deleted..."
        sleep 10
    done
    _PVS="$(kubectl get pv --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "${_PVS}" != "0" ]]; then
        printf '%b\n' "  ${YELLOW}WARN: ${_PVS} PersistentVolume(s) still present; their block-storage volumes may outlive the cluster. Check Volumes at cloud.linode.com after teardown.${RESET}"
    fi
else
    printf '%b\n' "  ${DIM}No kubeconfig found; skipping K8s cleanup${RESET}"
fi

# Step 1b: Object Storage teardown (account-level — survives terraform destroy).
# Revoke every per-student key + empty/delete every bucket prefixed by the run label.
# Idempotent and prefix-filtered, so it is a safe no-op when object_storage was never
# managed. The bucket prefix is the cluster label (deploy.sh passes --prefix "$LABEL").
# Buckets are matched in whatever region they live (they may not be in the cluster
# region: us-sea clusters keep their buckets in us-ord). REST API only, no linode-cli.
if [[ -n "$CLUSTER_LABEL" ]]; then
    echo ""
    printf '%b\n' "  ${BOLD}Step 1b: Object Storage cleanup${RESET}"
    env LINODE_CLI_TOKEN="${TF_VAR_token:-${LINODE_TOKEN:-}}" \
        "${SCRIPT_DIR}/provision-object-storage.sh" --teardown \
        --prefix "$CLUSTER_LABEL" \
        || printf '%b\n' "  ${DIM}(object-storage cleanup reported issues — verify in cloud.linode.com)${RESET}"
fi

# Step 2: Terraform destroy.
# In-cluster-only charts (gpu-operator, cloud-firewall CRD/controller) die with
# the cluster anyway — helm-uninstalling them first is wasted time and can
# deadlock: terraform removes the controller before the CRD chart, nothing is
# left to clear the CRD finalizers, and the uninstall hangs to its 5m timeout,
# aborting the destroy with the cluster still up (and billing). Drop them from
# state so destroy goes straight for the cluster. ingress-nginx stays managed:
# its uninstall is what deletes the cloud NodeBalancer.
echo ""
printf '%b\n' "  ${BOLD}Step 2: Terraform destroy${RESET}"
cd "${TF_DIR}"
for _REL in helm_release.cloud_firewall_crd helm_release.cloud_firewall_controller helm_release.gpu_operator; do
    terraform state rm "$_REL" >/dev/null 2>&1 || true
done
TF_DESTROY_RC=0
terraform destroy -auto-approve || TF_DESTROY_RC=$?

# Step 3: Clean up stale DNS records (survives lost Terraform state).
# When Terraform state is wiped, the DNS records from previous deploys remain
# and stack up on the next deploy. This step removes them via the Linode API.
# Pick the first candidate token the API accepts for Domains — a stale
# LINODE_TOKEN in a shell profile must not 401 this step into a no-op.
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
_DOMAIN=""
_PREFIX=""
if [[ -f "${TF_DIR}/terraform.tfvars" ]]; then
    _DOMAIN="$(grep -E '^[[:space:]]*domain[[:space:]]*=' "${TF_DIR}/terraform.tfvars" 2>/dev/null \
        | head -1 | sed -nE 's/.*=[[:space:]]*"([^"]+)".*/\1/p' || true)"
    _PREFIX="$(grep -E '^[[:space:]]*subdomain_prefix[[:space:]]*=' "${TF_DIR}/terraform.tfvars" 2>/dev/null \
        | head -1 | sed -nE 's/.*=[[:space:]]*"([^"]+)".*/\1/p' || true)"
fi
_PREFIX="${_PREFIX:-workshop}"

if [[ -z "$_TOKEN" && -n "$_DOMAIN" ]]; then
    printf '%b\n' "  ${DIM}WARN: no token the Linode API accepts for Domains — skipping DNS cleanup.${RESET}"
    printf '%b\n' "  ${DIM}Stale ${_PREFIX}.${_DOMAIN} A records may remain (next deploy pre-cleans them).${RESET}"
fi

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

# Final status — verify against the API rather than assert. A failed destroy
# once printed "All resources destroyed." while the cluster kept billing.
_SURVIVOR=""
if [[ -n "$_TOKEN" && -n "$CLUSTER_LABEL" ]]; then
    _SURVIVOR="$(python3 - "$_TOKEN" "$CLUSTER_LABEL" <<'PY'
import json, sys, urllib.request
token, label = sys.argv[1], sys.argv[2]
try:
    req = urllib.request.Request("https://api.linode.com/v4/lke/clusters?page_size=500",
                                 headers={"Authorization": "Bearer " + token})
    with urllib.request.urlopen(req, timeout=15) as r:
        for c in json.load(r).get("data", []):
            if c["label"] == label:
                print(c["id"])
                break
except Exception:
    pass
PY
)"
fi

# Local cleanup — but keep the kubeconfig if the cluster survived; you need it.
if [[ -z "$_SURVIVOR" ]]; then
    rm -f "${KUBECONFIG_PATH}"
    rm -rf "${INFRA_DIR}/manifests/generated"
fi

echo ""
rule
if [[ -n "$_SURVIVOR" ]]; then
    printf '%b\n' "  ${RED}${BOLD}TEARDOWN INCOMPLETE${RESET}${RED} — cluster '${CLUSTER_LABEL}' (id ${_SURVIVOR}) still exists and is billing.${RESET}"
    printf '%b\n' "  ${DIM}Re-run: ./deploy.sh teardown    (kubeconfig and generated/ kept for debugging)${RESET}"
elif [[ "${TF_DESTROY_RC}" -ne 0 ]]; then
    printf '%b\n' "  ${YELLOW}${BOLD}Teardown finished with terraform errors${RESET}${YELLOW} (exit ${TF_DESTROY_RC}).${RESET}"
    printf '%b\n' "  ${DIM}The cluster is gone per the API, but check https://cloud.linode.com for leftovers.${RESET}"
else
    printf '%b\n' "  ${GREEN}${BOLD}All resources destroyed.${RESET}"
fi
rule
echo ""

# Exit status: 1 when the cluster survived (still billing), 2 when terraform reported
# errors but the cluster is gone, 0 only when everything was destroyed. Callers and
# automation must not read a failed teardown as success.
if [[ -n "$_SURVIVOR" ]]; then
    exit 1
elif [[ "${TF_DESTROY_RC}" -ne 0 ]]; then
    exit 2
fi
exit 0
