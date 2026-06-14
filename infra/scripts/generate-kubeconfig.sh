#!/usr/bin/env bash
set -euo pipefail

# generate-kubeconfig.sh — mint per-student SCOPED kubeconfigs (cluster_access=scoped).
#
# For each student namespace <namespace>-sNN this requests a bound token for the
# `student` ServiceAccount (created by infra/helm/templates/student-namespaces.yaml)
# and emits a Secret `ws-NN-kubeconfig` (key: config) whose embedded kubeconfig is
# locked to that namespace (default context = the student's namespace). The workspace
# pod mounts that Secret at ~/.kube/config, so in-notebook `kubectl` is fenced to the
# student's own namespace by RBAC.
#
# The operator admin kubeconfig is NEVER shipped into a workspace — only a short-lived,
# namespace-scoped SA token is. Output lands in infra/manifests/generated/ (gitignored).
#
# Runs AFTER helm has created the namespaces + ServiceAccounts (so `create token`
# resolves). Re-running mints fresh tokens (old ones stay valid until they expire).
#
# Usage: ./generate-kubeconfig.sh -n 80 --namespace workshop

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
# Overridable so tests can render into an isolated dir (default: the gitignored generated/).
OUTPUT_DIR="${OUTPUT_DIR:-${INFRA_DIR}/manifests/generated}"
OUT="${OUTPUT_DIR}/workspace-kubeconfigs.yaml"
OUT_TMP="${OUT}.tmp"

COUNT=80
NAMESPACE="${NAMESPACE:-workshop}"
SA="${SA:-student}"
# Bound-token lifetime. Defaults to 30 days so a multi-day classroom outlives it;
# the API server may clamp it (a warning is printed). Override for longer events.
TOKEN_TTL="${KUBECONFIG_TTL:-720h}"
# Overridable for offline tests / unusual setups; otherwise derived from the current
# kubectl context.
KUBECTL="${KUBECTL:-kubectl}"
SERVER="${KUBECONFIG_SERVER:-}"
CA_DATA="${KUBECONFIG_CA_DATA:-}"

while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--count) COUNT="$2"; shift 2 ;;
        --namespace) NAMESPACE="$2"; shift 2 ;;
        --sa) SA="$2"; shift 2 ;;
        --ttl) TOKEN_TTL="$2"; shift 2 ;;
        --server) SERVER="$2"; shift 2 ;;
        --ca-data) CA_DATA="$2"; shift 2 ;;
        -h|--help)
            cat <<EOF
Usage: $0 [-n COUNT] [--namespace NS] [options]
  -n, --count      Number of students (default: 80)
  --namespace      Base namespace; students are <namespace>-sNN (default: workshop)
  --sa             ServiceAccount name in each student namespace (default: student)
  --ttl            Bound-token lifetime passed to 'kubectl create token' (default: 720h)
  --server         API server URL (default: derived from the current kubectl context)
  --ca-data        base64 cluster CA (default: derived from the current kubectl context)
EOF
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

mkdir -p "${OUTPUT_DIR}"

# Derive the API server + cluster CA from the current context unless overridden.
if [[ -z "${SERVER}" || -z "${CA_DATA}" ]]; then
    CTX="$("${KUBECTL}" config current-context)"
    CLUSTER="$("${KUBECTL}" config view -o jsonpath="{.contexts[?(@.name=='${CTX}')].context.cluster}")"
    if [[ -z "${CLUSTER}" ]]; then
        echo "ERROR: could not resolve the cluster for context '${CTX}'." >&2
        exit 1
    fi
    [[ -n "${SERVER}" ]] || SERVER="$("${KUBECTL}" config view -o jsonpath="{.clusters[?(@.name=='${CLUSTER}')].cluster.server}")"
    if [[ -z "${CA_DATA}" ]]; then
        CA_DATA="$("${KUBECTL}" config view --raw -o jsonpath="{.clusters[?(@.name=='${CLUSTER}')].cluster.certificate-authority-data}")"
        if [[ -z "${CA_DATA}" ]]; then
            # Some configs reference a CA file rather than inline data.
            CA_FILE="$("${KUBECTL}" config view --raw -o jsonpath="{.clusters[?(@.name=='${CLUSTER}')].cluster.certificate-authority}")"
            if [[ -n "${CA_FILE}" && -f "${CA_FILE}" ]]; then
                CA_DATA="$(base64 < "${CA_FILE}" | tr -d '\n')"
            fi
        fi
    fi
fi

if [[ -z "${SERVER}" ]]; then
    echo "ERROR: could not resolve the API server URL (pass --server)." >&2
    exit 1
fi

: > "${OUT_TMP}"
trap 'rm -f "${OUT_TMP}"' ERR

for i in $(seq 1 "${COUNT}"); do
    PADDED=$(printf "%02d" "$i")
    NS="${NAMESPACE}-s${PADDED}"
    TOKEN="$("${KUBECTL}" create token "${SA}" -n "${NS}" --duration="${TOKEN_TTL}")"
    if [[ -z "${TOKEN}" ]]; then
        echo "ERROR: empty token for ${SA} in ${NS} (does the namespace/SA exist yet?)." >&2
        exit 1
    fi

    # Build the embedded kubeconfig, then indent it under the Secret's stringData.
    KCFG="$(cat <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: cluster
    cluster:
      server: ${SERVER}
      certificate-authority-data: ${CA_DATA}
users:
  - name: ${SA}
    user:
      token: ${TOKEN}
contexts:
  - name: ${NS}
    context:
      cluster: cluster
      user: ${SA}
      namespace: ${NS}
current-context: ${NS}
EOF
)"

    cat >> "${OUT_TMP}" <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: ws-${PADDED}-kubeconfig
  namespace: ${NS}
  labels:
    app: akamai-workshop-platform
    awp-student-number: "${i}"
type: Opaque
stringData:
  config: |
$(printf '%s\n' "${KCFG}" | sed 's/^/    /')
EOF
done

mv "${OUT_TMP}" "${OUT}"

echo "Wrote ${COUNT} scoped kubeconfig Secrets → ${OUT}"
echo "  server: ${SERVER}"
echo "  ttl:    ${TOKEN_TTL}  (API server may clamp)"
echo "Apply with: kubectl apply -f ${OUT}"
