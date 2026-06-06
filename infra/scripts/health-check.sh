#!/usr/bin/env bash
set -euo pipefail

# Validate the full workshop stack.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
KUBECONFIG_PATH="${INFRA_DIR}/kubeconfig.yaml"
NAMESPACE="${NAMESPACE:-workshop}"
MODEL="${MODEL:-Qwen/Qwen3-8B-FP8}"

if [ -f "${KUBECONFIG_PATH}" ]; then
    export KUBECONFIG="${KUBECONFIG_PATH}"
fi

PASS=0
FAIL=0

check() {
    local label="$1"
    shift
    if "$@" > /dev/null 2>&1; then
        echo "  ✓ ${label}"
        PASS=$((PASS + 1))
    else
        echo "  ✗ ${label}"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== AI Agents Workshop — Health Check ==="
echo ""

# vLLM pods
echo "--- vLLM Inference ---"
VLLM_READY=$(kubectl -n "${NAMESPACE}" get pods -l app=vllm --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "${VLLM_READY}" -ge 1 ]; then
    echo "  ✓ vLLM pods running: ${VLLM_READY}"
    PASS=$((PASS + 1))
else
    echo "  ✗ No vLLM pods running"
    FAIL=$((FAIL + 1))
fi

# vLLM health endpoint — exec into a vllm pod and hit loopback (intra-pod, not affected by NetworkPolicy)
check "vLLM /health endpoint" kubectl -n "${NAMESPACE}" exec vllm-0 -- curl -sf http://localhost:8000/health

# Test inference
echo ""
echo "--- Test Inference ---"
TEST_RESULT=$(kubectl -n "${NAMESPACE}" exec vllm-0 -- curl -sf http://localhost:8000/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello\"}],\"max_tokens\":10}" 2>/dev/null || echo "FAIL")
if echo "${TEST_RESULT}" | grep -q "choices"; then
    echo "  ✓ Test inference successful"
    PASS=$((PASS + 1))
else
    echo "  ✗ Test inference failed"
    FAIL=$((FAIL + 1))
fi

# Workspace pods
echo ""
echo "--- Workspace Pods ---"
WS_TOTAL=$(kubectl -n "${NAMESPACE}" get pods -l app=workspace --no-headers 2>/dev/null | wc -l | tr -d ' ')
WS_RUNNING=$(kubectl -n "${NAMESPACE}" get pods -l app=workspace --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo "  Workspaces: ${WS_RUNNING}/${WS_TOTAL} running"

if [ "${WS_TOTAL}" -gt 0 ]; then
    # Test a sample workspace
    SAMPLE_POD=$(kubectl -n "${NAMESPACE}" get pods -l app=workspace --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "${SAMPLE_POD}" ]; then
        check "Sample workspace (${SAMPLE_POD}) — code-server responds" \
            kubectl -n "${NAMESPACE}" exec "${SAMPLE_POD}" -- curl -sf http://localhost:8080/healthz

        check "Sample workspace — can reach vLLM" \
            kubectl -n "${NAMESPACE}" exec "${SAMPLE_POD}" -- curl -sf http://vllm:8000/health

        check "Sample workspace — 00_verify.py passes" \
            kubectl -n "${NAMESPACE}" exec "${SAMPLE_POD}" -- bash -c "cd /home/coder/workshop && .venv/bin/python 00_verify.py"
    fi
fi

# Summary
echo ""
echo "=== Summary ==="
echo "  Passed: ${PASS}"
echo "  Failed: ${FAIL}"
echo ""

if [ "${FAIL}" -gt 0 ]; then
    echo "  ❌ Some checks failed. Review above."
    exit 1
else
    echo "  ✅ All checks passed!"
fi
