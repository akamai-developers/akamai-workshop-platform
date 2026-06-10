#!/usr/bin/env bash
set -euo pipefail

# Pre-warm vLLM pods by sending a test inference request.
# Run after deployment to ensure models are loaded into GPU memory.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
KUBECONFIG_PATH="${INFRA_DIR}/kubeconfig.yaml"
NAMESPACE="${NAMESPACE:-workshop}"
MODEL="${MODEL:-Qwen/Qwen3-8B-FP8}"
MODELS=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --model)  MODEL="$2"; shift 2 ;;
        --models) MODELS="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [ -f "${KUBECONFIG_PATH}" ]; then
    export KUBECONFIG="${KUBECONFIG_PATH}"
fi

echo "=== Pre-warming vLLM pods ==="
echo ""

if [ -n "${MODELS}" ]; then
    # Multi-model: warm each model's first pod.
    IFS=',' read -ra MODEL_LIST <<< "$MODELS"
    for m in "${MODEL_LIST[@]}"; do
        m="$(echo "$m" | xargs)"
        SLUG=$(printf '%s' "$m" | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-40)
        POD="vllm-${SLUG}-0"
        echo "  Warming ${POD} (${m})..."
        kubectl -n "${NAMESPACE}" exec "${POD}" -- curl -sf http://localhost:8000/v1/chat/completions \
            -H "Content-Type: application/json" \
            -d "{\"model\":\"${m}\",\"messages\":[{\"role\":\"user\",\"content\":\"What is 2+2?\"}],\"max_tokens\":20}" \
            > /dev/null 2>&1 && echo "    ✓ ${POD} warm" || echo "    ✗ ${POD} failed"
    done
else
    # Single-model: warm all vLLM pods.
    PODS=$(kubectl -n "${NAMESPACE}" get pods -l app=vllm -o jsonpath='{.items[*].metadata.name}')

    if [ -z "${PODS}" ]; then
        echo "No vLLM pods found. Run provision.sh first."
        exit 1
    fi

    for POD in ${PODS}; do
        echo "  Warming ${POD}..."
        kubectl -n "${NAMESPACE}" exec "${POD}" -- curl -sf http://localhost:8000/v1/chat/completions \
            -H "Content-Type: application/json" \
            -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"What is 2+2?\"}],\"max_tokens\":20}" \
            > /dev/null 2>&1 && echo "    ✓ ${POD} warm" || echo "    ✗ ${POD} failed"
    done
fi

echo ""
echo "=== Pre-warm complete ==="
