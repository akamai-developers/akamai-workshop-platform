#!/usr/bin/env bash
set -euo pipefail

# Generate workspace pod manifests, secrets, services, ingress, and access cards.
# Subdomain routing: each student gets sNN.<base-host>.
#
# Idempotent by default: re-running with the same -n and --host preserves
# passwords from access-cards.csv and only re-emits derived YAMLs. Use --rotate
# to mint fresh passwords; use --shrink to allow N to drop below existing count.
#
# Usage: ./generate-pods.sh -n 80 --host "$(cd ../terraform && terraform output -raw base_host)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="${INFRA_DIR}/manifests/generated"
TEMPLATE="${INFRA_DIR}/manifests/workspace-pod-template.yaml"
STARTUP_SCRIPT="${INFRA_DIR}/images/workspace/startup.sh"

CSV="${OUTPUT_DIR}/access-cards.csv"
SECRETS="${OUTPUT_DIR}/workspace-secrets.yaml"
MANIFESTS="${OUTPUT_DIR}/workspace-manifests.yaml"
INGRESS="${OUTPUT_DIR}/ingress.yaml"
CONFIGMAP="${OUTPUT_DIR}/workspace-startup-configmap.yaml"

CSV_TMP="${CSV}.tmp"
SECRETS_TMP="${SECRETS}.tmp"
MANIFESTS_TMP="${MANIFESTS}.tmp"
INGRESS_TMP="${INGRESS}.tmp"
CONFIGMAP_TMP="${CONFIGMAP}.tmp"

COUNT=80
HOST=""
TLS_SECRET="workshop-tls"
ROTATE=0
SHRINK=0

# Classroom-wide values stamped into every workspace. Flags override env, env
# overrides these defaults (the wizard passes them explicitly).
NAMESPACE="${NAMESPACE:-workshop}"
WORKSPACE_IMAGE="${WORKSPACE_IMAGE:-ghcr.io/akamai-developers/ai-agents-workspace:latest}"
MODEL="${MODEL:-Qwen/Qwen3-8B-FP8}"
VLLM_HOST="${VLLM_HOST:-http://vllm:8000/v1}"
CONTENT_REPO="${CONTENT_REPO:-}"

while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--count) COUNT="$2"; shift 2 ;;
        --host) HOST="$2"; shift 2 ;;
        --tls-secret) TLS_SECRET="$2"; shift 2 ;;
        --namespace) NAMESPACE="$2"; shift 2 ;;
        --image) WORKSPACE_IMAGE="$2"; shift 2 ;;
        --model) MODEL="$2"; shift 2 ;;
        --vllm-host) VLLM_HOST="$2"; shift 2 ;;
        --content-repo) CONTENT_REPO="$2"; shift 2 ;;
        --rotate) ROTATE=1; shift ;;
        --shrink) SHRINK=1; shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 [-n COUNT] --host BASE_HOST [options]
  -n, --count       Number of student workspaces (default: 80)
  --host            Base hostname; students get sNN.<base> (required; e.g. terraform output base_host)
  --tls-secret      TLS secret name referenced by the Ingress (default: workshop-tls)
  --namespace       Kubernetes namespace (default: workshop)
  --image           Workspace container image (default: stock prebuilt image)
  --model           MODEL_NAME env stamped into each workspace (default: Qwen/Qwen3-8B-FP8)
  --vllm-host       VLLM_HOST env stamped into each workspace (default: http://vllm:8000/v1)
  --content-repo    CONTENT_REPO env (git repo cloned at pod startup; "" → default)
  --rotate          Mint fresh passwords for every student. Required to change --host.
  --shrink          Allow N to be smaller than existing CSV; trimmed entries archived to .bak.
EOF
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

mkdir -p "${OUTPUT_DIR}"

cleanup_tmp() {
    rm -f "${CSV_TMP}" "${SECRETS_TMP}" "${MANIFESTS_TMP}" "${INGRESS_TMP}" "${CONFIGMAP_TMP}"
}
trap cleanup_tmp ERR

PASSWORDS=()
EXISTING_COUNT=0
OLD_HOST=""

read_existing_csv() {
    [[ -f "${CSV}" ]] || return 0

    local line_num=0
    local expected=1
    local num url password row_host n

    while IFS=, read -r num url password || [[ -n "${num}" ]]; do
        line_num=$((line_num + 1))
        # Strip CR in case of CRLF line endings
        password="${password%$'\r'}"

        if [[ ${line_num} -eq 1 ]]; then
            if [[ "${num}" != "student_number" ]]; then
                echo "ERROR: ${CSV} missing expected header 'student_number,url,password'." >&2
                echo "Delete the file or pass --rotate to regenerate." >&2
                exit 1
            fi
            continue
        fi

        if [[ ! "${num}" =~ ^s([0-9]{2})$ ]]; then
            echo "ERROR: ${CSV} line ${line_num}: invalid student id '${num}'." >&2
            exit 1
        fi
        n=$((10#${BASH_REMATCH[1]}))

        if [[ ${n} -ne ${expected} ]]; then
            echo "ERROR: ${CSV} has gap or out-of-order numbering at line ${line_num} (got ${num}, expected s$(printf "%02d" ${expected}))." >&2
            exit 1
        fi
        expected=$((expected + 1))

        if [[ ! "${url}" =~ ^https://s[0-9]{2}\.(.+)/$ ]]; then
            echo "ERROR: ${CSV} line ${line_num}: cannot parse URL '${url}'." >&2
            exit 1
        fi
        row_host="${BASH_REMATCH[1]}"
        if [[ -z "${OLD_HOST}" ]]; then
            OLD_HOST="${row_host}"
        elif [[ "${OLD_HOST}" != "${row_host}" ]]; then
            echo "ERROR: ${CSV} contains mixed hosts ('${OLD_HOST}' and '${row_host}'). Pass --rotate to regenerate." >&2
            exit 1
        fi

        if [[ -z "${password}" ]]; then
            echo "ERROR: ${CSV} line ${line_num}: empty password for ${num}." >&2
            exit 1
        fi

        PASSWORDS[${n}]="${password}"
        EXISTING_COUNT=${n}
    done < "${CSV}"
}

read_existing_csv

# Decision matrix
MODE=""
if [[ ${EXISTING_COUNT} -eq 0 ]]; then
    if [[ ${SHRINK} -eq 1 ]]; then
        echo "ERROR: --shrink passed but no existing ${CSV} to shrink." >&2
        exit 1
    fi
    MODE="initial"
elif [[ ${ROTATE} -eq 1 ]]; then
    MODE="rotate-all"
elif [[ "${OLD_HOST}" != "${HOST}" ]]; then
    echo "ERROR: existing ${CSV} uses host '${OLD_HOST}', requested '${HOST}'." >&2
    echo "Re-run with --rotate to regenerate everything under the new host (all passwords will be rotated)." >&2
    exit 1
elif [[ ${COUNT} -lt ${EXISTING_COUNT} ]]; then
    if [[ ${SHRINK} -eq 0 ]]; then
        echo "ERROR: requested N=${COUNT} is smaller than existing CSV (${EXISTING_COUNT} students)." >&2
        echo "Pass --shrink to trim s$(printf "%02d" $((COUNT + 1)))–s$(printf "%02d" ${EXISTING_COUNT}) (archived to access-cards.csv.bak), or --rotate to regenerate." >&2
        exit 1
    fi
    MODE="shrink"
elif [[ ${COUNT} -eq ${EXISTING_COUNT} ]]; then
    MODE="preserve"
else
    MODE="mint-new"
fi

case "${MODE}" in
    initial)
        for i in $(seq 1 "${COUNT}"); do
            PASSWORDS[${i}]="$(openssl rand -hex 16)"
        done
        ;;
    rotate-all)
        PASSWORDS=()
        for i in $(seq 1 "${COUNT}"); do
            PASSWORDS[${i}]="$(openssl rand -hex 16)"
        done
        ;;
    preserve)
        :
        ;;
    mint-new)
        for i in $(seq $((EXISTING_COUNT + 1)) "${COUNT}"); do
            PASSWORDS[${i}]="$(openssl rand -hex 16)"
        done
        ;;
    shrink)
        for i in $(seq $((COUNT + 1)) "${EXISTING_COUNT}"); do
            unset "PASSWORDS[${i}]"
        done
        ;;
esac

# Back up old CSV before overwriting
if [[ -f "${CSV}" ]]; then
    cp "${CSV}" "${CSV}.bak"
fi

# Emit all four artifacts to .tmp siblings, then move into place atomically.

echo "student_number,url,password" > "${CSV_TMP}"
: > "${SECRETS_TMP}"
: > "${MANIFESTS_TMP}"

cat > "${INGRESS_TMP}" << EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: workshop-ingress
  namespace: ${NAMESPACE}
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
EOF

for i in $(seq 1 "${COUNT}"); do
    PADDED=$(printf "%02d" "$i")
    echo "        - s${PADDED}.${HOST}" >> "${INGRESS_TMP}"
done

cat >> "${INGRESS_TMP}" << EOF
      secretName: ${TLS_SECRET}
  rules:
EOF

for i in $(seq 1 "${COUNT}"); do
    PADDED=$(printf "%02d" "$i")
    PASSWORD="${PASSWORDS[$i]}"
    SECRET_NAME="ws-${PADDED}-password"

    cat >> "${SECRETS_TMP}" << EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  password: "${PASSWORD}"
EOF

    sed -e "s/STUDENT_NUM_PADDED/${PADDED}/g" \
        -e "s/STUDENT_NUM/${i}/g" \
        -e "s/PASSWORD_SECRET_NAME/${SECRET_NAME}/g" \
        -e "s|__NAMESPACE__|${NAMESPACE}|g" \
        -e "s|__WORKSPACE_IMAGE__|${WORKSPACE_IMAGE}|g" \
        -e "s|__VLLM_HOST__|${VLLM_HOST}|g" \
        -e "s|__MODEL__|${MODEL}|g" \
        -e "s|__CONTENT_REPO__|${CONTENT_REPO}|g" \
        "${TEMPLATE}" >> "${MANIFESTS_TMP}"
    echo "---" >> "${MANIFESTS_TMP}"

    cat >> "${INGRESS_TMP}" << EOF
    - host: s${PADDED}.${HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ws-${PADDED}
                port:
                  number: 8080
EOF

    echo "s${PADDED},https://s${PADDED}.${HOST}/,${PASSWORD}" >> "${CSV_TMP}"
done

# Emit the shared workspace-startup ConfigMap from the canonical startup.sh.
# Every workspace pod mounts this and runs it as its command (clones content, etc.).
if [[ ! -f "${STARTUP_SCRIPT}" ]]; then
    echo "ERROR: startup script not found at ${STARTUP_SCRIPT}" >&2
    exit 1
fi
cat > "${CONFIGMAP_TMP}" << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: workspace-startup
  namespace: ${NAMESPACE}
data:
  startup.sh: |
$(sed 's/^/    /' "${STARTUP_SCRIPT}")
EOF

mv "${CSV_TMP}" "${CSV}"
mv "${SECRETS_TMP}" "${SECRETS}"
mv "${MANIFESTS_TMP}" "${MANIFESTS}"
mv "${INGRESS_TMP}" "${INGRESS}"
mv "${CONFIGMAP_TMP}" "${CONFIGMAP}"

echo ""
echo "=== Done: *.${HOST} ==="
case "${MODE}" in
    initial)
        echo "Minted ${COUNT} workspaces (s01–s$(printf "%02d" ${COUNT}))."
        ;;
    rotate-all)
        echo "Rotated all ${COUNT} passwords. Previous CSV archived to access-cards.csv.bak"
        ;;
    preserve)
        echo "Preserved ${COUNT} passwords; re-emitted derived YAMLs only. access-cards.csv unchanged."
        ;;
    mint-new)
        echo "Preserved s01–s$(printf "%02d" ${EXISTING_COUNT}); minted s$(printf "%02d" $((EXISTING_COUNT + 1)))–s$(printf "%02d" ${COUNT}) ($((COUNT - EXISTING_COUNT)) new)."
        ;;
    shrink)
        echo "Trimmed to ${COUNT}. Archived s$(printf "%02d" $((COUNT + 1)))–s$(printf "%02d" ${EXISTING_COUNT}) ($((EXISTING_COUNT - COUNT)) entries) via access-cards.csv.bak"
        ;;
esac

echo ""
echo "Files:"
echo "  ${CONFIGMAP}"
echo "  ${SECRETS}"
echo "  ${MANIFESTS}"
echo "  ${INGRESS}"
echo "  ${CSV}"
echo ""
echo "Deploy (the whole generated/ dir applies in dependency order):"
echo "  kubectl apply -f ${OUTPUT_DIR}/"
echo "  # or individually — ConfigMap before the pods that mount it:"
echo "  kubectl apply -f ${CONFIGMAP}"
echo "  kubectl apply -f ${SECRETS}"
echo "  kubectl apply -f ${MANIFESTS}"
echo "  kubectl apply -f ${INGRESS}"
