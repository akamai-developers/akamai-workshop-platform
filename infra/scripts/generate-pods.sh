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
# Overridable so tests can render into an isolated dir (default: the gitignored generated/).
OUTPUT_DIR="${OUTPUT_DIR:-${INFRA_DIR}/manifests/generated}"
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
MODEL_NAMES=""
VLLM_HOST="${VLLM_HOST:-http://vllm:8000/v1}"
CONTENT_REPO="${CONTENT_REPO:-}"
# Key students' OpenAI client sends as `Authorization: Bearer`. "not-needed" is the
# harmless default when the endpoint has no auth; set to the real key when the
# agentgateway enforces apiKeyAuthentication.
VLLM_API_KEY="${VLLM_API_KEY:-not-needed}"
# editor component: code-server (default) | jupyter. Threaded into the pod's
# WORKSPACE_TYPE env, which startup.sh branches on. Default emits NO env (byte-identical).
WORKSPACE_TYPE="${WORKSPACE_TYPE:-code-server}"
# cluster_access component: none (default) | scoped. In scoped mode each student's
# workspace + ingress + secret + startup ConfigMap land in their OWN namespace
# (<namespace>-sNN), and a per-student scoped kubeconfig Secret is mounted at ~/.kube.
CLUSTER_ACCESS="${CLUSTER_ACCESS:-none}"
# agent_deploy component: none (default) | plain. Only meaningful with cluster_access=scoped.
# plain emits a per-student agent Deployment+Service (workspace image + clone-at-startup,
# WORKSPACE_TYPE=agent) in the student namespace, fronted by an agent-sNN.<host> ingress.
AGENT_DEPLOY="${AGENT_DEPLOY:-none}"

while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--count) COUNT="$2"; shift 2 ;;
        --host) HOST="$2"; shift 2 ;;
        --tls-secret) TLS_SECRET="$2"; shift 2 ;;
        --namespace) NAMESPACE="$2"; shift 2 ;;
        --image) WORKSPACE_IMAGE="$2"; shift 2 ;;
        --model) MODEL="$2"; shift 2 ;;
        --model-names) MODEL_NAMES="$2"; shift 2 ;;
        --vllm-host) VLLM_HOST="$2"; shift 2 ;;
        --content-repo) CONTENT_REPO="$2"; shift 2 ;;
        --api-key) VLLM_API_KEY="$2"; shift 2 ;;
        --workspace-type) WORKSPACE_TYPE="$2"; shift 2 ;;
        --cluster-access) CLUSTER_ACCESS="$2"; shift 2 ;;
        --agent-deploy) AGENT_DEPLOY="$2"; shift 2 ;;
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
  --model-names     MODEL_NAMES env (comma-separated, multi-model; defaults to --model)
  --vllm-host       VLLM_HOST env stamped into each workspace (default: http://vllm:8000/v1)
  --content-repo    CONTENT_REPO env (git repo cloned at pod startup; "" → default)
  --api-key         VLLM_API_KEY env (sent as Bearer to the gateway; "not-needed" if no auth)
  --workspace-type  Editor: code-server (default) | jupyter (sets WORKSPACE_TYPE env)
  --cluster-access  none (default) | scoped — per-student namespace + scoped kubeconfig mount
  --agent-deploy    none (default) | plain — per-student agent Deployment+Service (needs scoped)
  --rotate          Mint fresh passwords for every student. Required to change --host.
  --shrink          Allow N to be smaller than existing CSV; trimmed entries archived to .bak.
EOF
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# An empty host (e.g. a failed 'terraform output -raw base_host' substitution)
# would emit invalid ingress hosts like "s01." and poison access-cards.csv.
if [[ -z "${HOST}" ]]; then
    echo "ERROR: --host is required (e.g. --host \$(cd ../terraform && terraform output -raw base_host))" >&2
    exit 1
fi

# Default MODEL_NAMES to MODEL if not set.
MODEL_NAMES="${MODEL_NAMES:-$MODEL}"

case "${CLUSTER_ACCESS}" in none|scoped) ;; *) echo "ERROR: --cluster-access must be 'none' or 'scoped' (got '${CLUSTER_ACCESS}')" >&2; exit 1 ;; esac
case "${AGENT_DEPLOY}" in none|plain) ;; *) echo "ERROR: --agent-deploy must be 'none' or 'plain' (got '${AGENT_DEPLOY}')" >&2; exit 1 ;; esac
if [[ "${AGENT_DEPLOY}" != "none" && "${CLUSTER_ACCESS}" != "scoped" ]]; then
    echo "ERROR: --agent-deploy '${AGENT_DEPLOY}' requires --cluster-access scoped (the agent ships into the student namespace)." >&2
    exit 1
fi

# Namespace a given padded student id lands in. Default mode: the single shared
# namespace (byte-identical to today). Scoped mode: one namespace per student,
# matching the helm-rendered student-namespaces.yaml (<namespace>-sNN).
student_ns() {
    if [[ "${CLUSTER_ACCESS}" == "scoped" ]]; then
        printf '%s-s%s' "${NAMESPACE}" "$1"
    else
        printf '%s' "${NAMESPACE}"
    fi
}

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
: > "${CONFIGMAP_TMP}"

# The workspace-startup ConfigMap is built from the canonical startup.sh. In the
# default mode it is emitted once (shared namespace) after the loop; in scoped mode
# it is emitted once per student namespace inside the loop. Prep the (indented) body
# now so both paths reuse it.
if [[ ! -f "${STARTUP_SCRIPT}" ]]; then
    echo "ERROR: startup script not found at ${STARTUP_SCRIPT}" >&2
    exit 1
fi
STARTUP_INDENTED="$(sed 's/^/    /' "${STARTUP_SCRIPT}")"

# Reusable annotations block for ingresses (kept identical across modes).
ingress_annotations() {
    cat << 'EOF'
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
EOF
}

if [[ "${CLUSTER_ACCESS}" == "scoped" ]]; then
    # Scoped: each student gets a self-contained Ingress in their own namespace
    # (emitted inside the loop), so start with an empty ingress file.
    : > "${INGRESS_TMP}"
else
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
fi

for i in $(seq 1 "${COUNT}"); do
    PADDED=$(printf "%02d" "$i")
    PASSWORD="${PASSWORDS[$i]}"
    SECRET_NAME="ws-${PADDED}-password"
    NS_I="$(student_ns "${PADDED}")"
    KCFG_SECRET="ws-${PADDED}-kubeconfig"

    cat >> "${SECRETS_TMP}" << EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${NS_I}
type: Opaque
stringData:
  password: "${PASSWORD}"
EOF

    sed -e "s/STUDENT_NUM_PADDED/${PADDED}/g" \
        -e "s/STUDENT_NUM/${i}/g" \
        -e "s/PASSWORD_SECRET_NAME/${SECRET_NAME}/g" \
        -e "s|__NAMESPACE__|${NS_I}|g" \
        -e "s|__WORKSPACE_IMAGE__|${WORKSPACE_IMAGE}|g" \
        -e "s|__VLLM_HOST__|${VLLM_HOST}|g" \
        -e "s|__MODEL__|${MODEL}|g" \
        -e "s|__MODEL_NAMES__|${MODEL_NAMES}|g" \
        -e "s|__CONTENT_REPO__|${CONTENT_REPO}|g" \
        -e "s|__VLLM_API_KEY__|${VLLM_API_KEY}|g" \
        "${TEMPLATE}" \
      | awk -v wt="${WORKSPACE_TYPE}" -v ca="${CLUSTER_ACCESS}" -v kc="${KCFG_SECRET}" '
          /__WORKSPACE_TYPE_ENV__/ {
            # Default code-server: drop the sentinel entirely (byte-identical output).
            # Otherwise emit the WORKSPACE_TYPE env that startup.sh branches on.
            if (wt != "code-server") {
              print "        - name: WORKSPACE_TYPE"
              print "          value: \"" wt "\""
            }
            next
          }
          /__KUBECONFIG_MOUNT__/ {
            # Default (cluster_access=none): drop the sentinel (byte-identical output).
            # Scoped: mount the per-student scoped kubeconfig Secret at ~/.kube so the
            # in-notebook kubectl uses it (NEVER the operator admin kubeconfig).
            if (ca == "scoped") {
              print "        - name: kubeconfig"
              print "          mountPath: /home/coder/.kube"
              print "          readOnly: true"
            }
            next
          }
          /__KUBECONFIG_VOLUME__/ {
            if (ca == "scoped") {
              print "    - name: kubeconfig"
              print "      secret:"
              print "        secretName: " kc
              print "        optional: true"
            }
            next
          }
          { print }' \
        >> "${MANIFESTS_TMP}"
    echo "---" >> "${MANIFESTS_TMP}"

    if [[ "${CLUSTER_ACCESS}" == "scoped" ]]; then
        # Self-contained per-student Ingress in the student's namespace (its backend
        # Services must be co-located, so one Ingress per namespace). The wildcard
        # *.<host> cert/DNS already covers sNN.<host> AND agent-sNN.<host>.
        {
            cat << EOF
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: workshop-ingress
  namespace: ${NS_I}
EOF
            ingress_annotations
            cat << EOF
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - s${PADDED}.${HOST}
EOF
            [[ "${AGENT_DEPLOY}" == "plain" ]] && echo "        - agent-s${PADDED}.${HOST}"
            cat << EOF
      secretName: ${TLS_SECRET}
  rules:
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
            if [[ "${AGENT_DEPLOY}" == "plain" ]]; then
                cat << EOF
    - host: agent-s${PADDED}.${HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: agent
                port:
                  number: 8080
EOF
            fi
        } >> "${INGRESS_TMP}"

        # Per-student-namespace copy of the workspace-startup ConfigMap (the pod
        # mounts it from its own namespace).
        cat >> "${CONFIGMAP_TMP}" << EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: workspace-startup
  namespace: ${NS_I}
data:
  startup.sh: |
${STARTUP_INDENTED}
EOF

        # agent_deploy: plain — a per-student agent Deployment+Service reusing the
        # workspace image + clone-at-startup (WORKSPACE_TYPE=agent runs the repo's
        # run-agent.sh). "Deploy" = kubectl apply; "modify" = kubectl rollout restart.
        if [[ "${AGENT_DEPLOY}" == "plain" ]]; then
            cat >> "${MANIFESTS_TMP}" << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: agent
  namespace: ${NS_I}
  labels:
    app: agent
    student: "${i}"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: agent
      student: "${i}"
  template:
    metadata:
      labels:
        app: agent
        student: "${i}"
    spec:
      automountServiceAccountToken: false
      containers:
        - name: agent
          image: ${WORKSPACE_IMAGE}
          command: ["/bin/bash", "/workshop-scripts/startup.sh"]
          ports:
            - containerPort: 8080
              name: http
          env:
            - name: WORKSPACE_TYPE
              value: "agent"
            - name: VLLM_HOST
              value: "${VLLM_HOST}"
            - name: MODEL_NAME
              value: "${MODEL}"
            - name: MODEL_NAMES
              value: "${MODEL_NAMES}"
            - name: CONTENT_REPO
              value: "${CONTENT_REPO}"
            - name: VLLM_API_KEY
              value: "${VLLM_API_KEY}"
          resources:
            requests:
              cpu: "250m"
              memory: "512Mi"
            limits:
              cpu: "1"
              memory: "1Gi"
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
            seccompProfile:
              type: RuntimeDefault
          volumeMounts:
            - name: startup
              mountPath: /workshop-scripts
              readOnly: true
      volumes:
        - name: startup
          configMap:
            name: workspace-startup
---
apiVersion: v1
kind: Service
metadata:
  name: agent
  namespace: ${NS_I}
  labels:
    app: agent
    student: "${i}"
spec:
  type: ClusterIP
  selector:
    app: agent
    student: "${i}"
  ports:
    - port: 8080
      targetPort: 8080
      protocol: TCP
---
EOF
        fi
    else
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
    fi

    echo "s${PADDED},https://s${PADDED}.${HOST}/,${PASSWORD}" >> "${CSV_TMP}"
done

# Default mode emits ONE shared workspace-startup ConfigMap (scoped mode already
# emitted a per-namespace copy inside the loop). Byte-identical to the original.
if [[ "${CLUSTER_ACCESS}" != "scoped" ]]; then
    cat > "${CONFIGMAP_TMP}" << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: workspace-startup
  namespace: ${NAMESPACE}
data:
  startup.sh: |
${STARTUP_INDENTED}
EOF
fi

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
