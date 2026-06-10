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

# Detect multi-model by checking for agentgateway resources.
MULTI_MODEL=0
if kubectl -n "${NAMESPACE}" get gateway agentgateway-proxy >/dev/null 2>&1; then
    MULTI_MODEL=1
    echo "--- Mode: Multi-Model (agentgateway detected) ---"
else
    echo "--- Mode: Single-Model ---"
fi
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

if [ "${MULTI_MODEL}" -eq 0 ]; then
    # Single-model: check vllm-0 directly.
    check "vLLM /health endpoint" kubectl -n "${NAMESPACE}" exec vllm-0 -- curl -sf http://localhost:8000/health

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
else
    # Multi-model: check each vLLM StatefulSet and test inference through gateway.
    VLLM_SETS=$(kubectl -n "${NAMESPACE}" get statefulset -l app=vllm -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    for ss in ${VLLM_SETS}; do
        FIRST_POD="${ss}-0"
        check "${ss} /health" kubectl -n "${NAMESPACE}" exec "${FIRST_POD}" -- curl -sf http://localhost:8000/health
    done

    echo ""
    echo "--- Agentgateway ---"
    check "agentgateway Gateway exists" kubectl -n "${NAMESPACE}" get gateway agentgateway-proxy

    echo ""
    echo "--- Test Inference (via gateway) ---"
    GW_POD=$(kubectl -n "${NAMESPACE}" get pods -l app=workspace --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "${GW_POD}" ]; then
        for ss in ${VLLM_SETS}; do
            SS_MODEL=$(kubectl -n "${NAMESPACE}" get "statefulset/${ss}" -o jsonpath='{.spec.template.spec.containers[0].args[0]}' 2>/dev/null | sed 's/--model=//')
            if [ -n "${SS_MODEL}" ]; then
                TEST_RESULT=$(kubectl -n "${NAMESPACE}" exec "${GW_POD}" -- curl -sf http://agentgateway:8080/v1/chat/completions \
                    -H "Content-Type: application/json" \
                    -d "{\"model\":\"${SS_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello\"}],\"max_tokens\":10}" 2>/dev/null || echo "FAIL")
                if echo "${TEST_RESULT}" | grep -q "choices"; then
                    echo "  ✓ Inference via gateway for ${SS_MODEL}"
                    PASS=$((PASS + 1))
                else
                    echo "  ✗ Inference via gateway for ${SS_MODEL}"
                    FAIL=$((FAIL + 1))
                fi
            fi
        done
    else
        echo "  ⚠ No workspace pods running; skipping gateway inference test"
    fi
fi

# Workspace pods
echo ""
echo "--- Workspace Pods ---"
WS_TOTAL=$(kubectl -n "${NAMESPACE}" get pods -l app=workspace --no-headers 2>/dev/null | wc -l | tr -d ' ')
WS_RUNNING=$(kubectl -n "${NAMESPACE}" get pods -l app=workspace --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo "  Workspaces: ${WS_RUNNING}/${WS_TOTAL} running"

if [ "${WS_TOTAL}" -gt 0 ]; then
    SAMPLE_POD=$(kubectl -n "${NAMESPACE}" get pods -l app=workspace --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "${SAMPLE_POD}" ]; then
        check "Sample workspace (${SAMPLE_POD}) — code-server responds" \
            kubectl -n "${NAMESPACE}" exec "${SAMPLE_POD}" -- curl -sf http://localhost:8080/healthz

        if [ "${MULTI_MODEL}" -eq 0 ]; then
            check "Sample workspace — can reach vLLM" \
                kubectl -n "${NAMESPACE}" exec "${SAMPLE_POD}" -- curl -sf http://vllm:8000/health
        else
            check "Sample workspace — can reach agentgateway" \
                kubectl -n "${NAMESPACE}" exec "${SAMPLE_POD}" -- curl -sf http://agentgateway:8080/health
        fi

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
