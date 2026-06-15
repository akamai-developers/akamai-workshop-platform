#!/usr/bin/env bash
# End-to-end smoke test on REAL Akamai LKE. SPENDS MONEY (briefly).
#
# Provisions the CHEAPEST possible classroom headless, asserts the full chain
# (GPU → vLLM → student workspace → student→vLLM path → capacity-test), then
# ALWAYS tears everything down via an EXIT trap — even if an assertion fails.
#
# Footprint (deliberately minimal, ~ $0.75/hr):
#   1 student · Qwen/Qwen3-4B-Instruct-2507 · 1× g2-gpu-rtx4000a1-s (TP=1) ·
#   1 small CPU node · no domain (sslip.io + self-signed) · stock code-server image.
#
# Prereqs: a VALID $TF_VAR_token (or $LINODE_TOKEN); terraform, kubectl, helm,
# openssl, curl, linode-cli on PATH.
#
# Usage:  TF_VAR_token=... ./infra/scripts/e2e-smoke.sh   [--region us-ord]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(dirname "$INFRA_DIR")"
TF_DIR="${INFRA_DIR}/terraform"
KUBECONFIG_PATH="${INFRA_DIR}/kubeconfig.yaml"
RESULTS_MD="${INFRA_DIR}/docs/e2e-results.md"

export TF_VAR_token="${TF_VAR_token:-${LINODE_TOKEN:-}}"
REGION="${REGION:-us-ord}"
LABEL="awp-e2e-smoke"
NAMESPACE="${NAMESPACE:-workshop}"
MODEL="Qwen/Qwen3-4B-Instruct-2507"
# KEEP_CLUSTER=1 leaves the classroom UP after the run (skips the teardown trap) so it
# can be demoed / re-used. Default empty = always tear down (the original smoke behavior).
KEEP_CLUSTER="${KEEP_CLUSTER:-}"
# GPU_SHARING=timeslicing exercises the two-models-on-one-card path (default for this smoke
# now that it's a shipped feature). Set GPU_SHARING=none to test the exclusive-GPU baseline.
GPU_SHARING="${GPU_SHARING:-timeslicing}"
CONTENT_REPO="${CONTENT_REPO:-https://github.com/labeveryday/workshop-template.git}"
# This narrowed smoke exercises the own-inference composition — the only parts offline
# can't cover (real GPU + Cilium + a dedicated per-student vLLM + Jupyter + scoped kubectl).
# 1 student → resources land in the per-student namespace workshop-s01.
STUDENT_NS="${NAMESPACE}-s01"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --region) REGION="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

FAILURES=0
PASSES=0
START_TS="$(date +%s)"
declare -a RESULTS

note() { echo "[e2e] $*"; }
record() { RESULTS+=("$1"); }
assert() {  # assert "name" <command...>
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  [PASS] ${name}"; PASSES=$((PASSES+1)); record "PASS ${name}"
    else
        echo "  [FAIL] ${name}"; FAILURES=$((FAILURES+1)); record "FAIL ${name}"
    fi
}

# ---------------------------------------------------------------------------
# GUARANTEED TEARDOWN — runs on ANY exit (success, failure, Ctrl-C, set -e).
# ---------------------------------------------------------------------------
teardown() {
    if [ -n "$KEEP_CLUSTER" ]; then
        note "KEEP_CLUSTER set — leaving the classroom UP (it is BILLING)."
        note "  tear down later with:  TF_VAR_token=\$LINODE_TOKEN ./deploy.sh teardown --yes --namespace ${NAMESPACE}"
        return 0
    fi
    note "tearing down (always) ..."
    ( cd "$ROOT_DIR" && ./deploy.sh teardown --yes --namespace "$NAMESPACE" ) \
        || ( cd "$TF_DIR" && terraform destroy -auto-approve )
    # Object Storage is account-level (survives terraform destroy). deploy.sh teardown
    # already revokes/deletes by prefix; re-run here as a backstop for the destroy
    # fallback above. Idempotent + prefix-filtered, so a no-op when none was provisioned.
    LINODE_CLI_TOKEN="${TF_VAR_token}" "${SCRIPT_DIR}/provision-object-storage.sh" --teardown \
        --region "$REGION" --prefix "$LABEL" >/dev/null 2>&1 || true
    # Post-run leak check via REAL linode-cli — clusters AND account-level Object Storage
    # (buckets/keys survive terraform destroy). A survivor is a build FAILURE.
    note "verifying no '${LABEL}' resources remain (cluster + object storage) ..."
    if command -v linode-cli >/dev/null 2>&1; then
        local _leak=0
        LINODE_CLI_TOKEN="${TF_VAR_token}" linode-cli lke clusters-list --text 2>/dev/null \
            | grep -q "${LABEL}" \
            && { note "WARNING: cluster '${LABEL}' STILL PRESENT — delete it manually!"; _leak=1; } \
            || note "confirmed: no '${LABEL}' cluster."
        LINODE_CLI_TOKEN="${TF_VAR_token}" linode-cli object-storage buckets-list --text 2>/dev/null \
            | grep -q "${LABEL}" \
            && { note "WARNING: Object Storage bucket(s) for '${LABEL}' STILL PRESENT!"; _leak=1; } \
            || note "confirmed: no '${LABEL}' buckets."
        LINODE_CLI_TOKEN="${TF_VAR_token}" linode-cli object-storage keys-list --text 2>/dev/null \
            | grep -q "${LABEL}" \
            && { note "WARNING: Object Storage key(s) for '${LABEL}' STILL PRESENT!"; _leak=1; } \
            || note "confirmed: no '${LABEL}' keys."
        [ "$_leak" -eq 0 ] || note "LEAK CHECK FAILED — manual cleanup required."
    fi
}
trap teardown EXIT

# ---------------------------------------------------------------------------
# 0. Preflight
# ---------------------------------------------------------------------------
note "=== e2e smoke test — region=${REGION} label=${LABEL} ==="
if [ -z "${TF_VAR_token}" ]; then
    note "BLOCKED: no TF_VAR_token / LINODE_TOKEN set."; exit 3
fi
if ! curl -sf -H "Authorization: Bearer ${TF_VAR_token}" \
        https://api.linode.com/v4/profile >/dev/null; then
    note "BLOCKED: Linode API rejected the token (401). Export a valid TF_VAR_token."; exit 3
fi
for bin in terraform kubectl helm openssl curl; do
    command -v "$bin" >/dev/null 2>&1 || { note "BLOCKED: $bin not on PATH."; exit 3; }
done

# ---------------------------------------------------------------------------
# 1. Deploy the cheapest classroom (headless). deploy.sh runs terraform +
#    helm + vLLM + TLS + generate-pods. If this fails, the trap tears down.
# ---------------------------------------------------------------------------
note "--- deploying cheapest footprint (this provisions billing resources) ---"
(
  cd "$ROOT_DIR" && ./deploy.sh deploy --yes \
    --students 1 --model "$MODEL" \
    --editor jupyter --inference dedicated-vllm --cluster-access scoped \
    --gpus-per-student 1 --gpu-sharing "$GPU_SHARING" \
    --gpu-node-type g2-gpu-rtx4000a1-s --gpu-node-count 1 --tp 1 \
    --cpu-node-type g6-standard-4 --cpu-node-count 1 \
    --max-model-len 8192 --content-repo "$CONTENT_REPO" \
    --domain "" --region "$REGION" --label "$LABEL" --namespace "$NAMESPACE"
)
DEPLOY_RC=$?
if [ "$DEPLOY_RC" -ne 0 ]; then
    note "deploy failed (rc=${DEPLOY_RC}) — likely GPU capacity. Trap will tear down."
    record "FAIL deploy (rc=${DEPLOY_RC})"; FAILURES=$((FAILURES+1))
    exit 1
fi
record "PASS deploy (terraform apply + helm + generate-pods)"; PASSES=$((PASSES+1))

export KUBECONFIG="$KUBECONFIG_PATH"
BASE_HOST="$(cd "$TF_DIR" && terraform output -raw base_host 2>/dev/null)"
note "base host: ${BASE_HOST}"
PROVISION_TS="$(date +%s)"
COLD_START_MIN=$(( (PROVISION_TS - START_TS) / 60 ))

# ---------------------------------------------------------------------------
# 2. Assertions
# ---------------------------------------------------------------------------
note "--- asserting the chain ---"

# 2a. A node reports nvidia.com/gpu.
gpu_ready() {
    kubectl get nodes -o json | python3 -c \
      "import sys,json; d=json.load(sys.stdin); sys.exit(0 if any(int(n['status']['allocatable'].get('nvidia.com/gpu','0'))>=1 for n in d['items']) else 1)"
}
assert "GPU node reports nvidia.com/gpu" gpu_ready

# 2a-bis. Time-slicing took effect: the single physical GPU now advertises >= 2 logical
#         GPUs (gpu_sharing=timeslicing). Skipped when GPU_SHARING=none.
gpu_timesliced() {
    kubectl get nodes -o json | python3 -c \
      "import sys,json; d=json.load(sys.stdin); sys.exit(0 if any(int(n['status']['allocatable'].get('nvidia.com/gpu','0'))>=2 for n in d['items']) else 1)"
}
if [ "$GPU_SHARING" = "timeslicing" ]; then
    assert "time-slicing: one card advertises >= 2 logical GPUs" gpu_timesliced
fi

# 2a-ter. Co-tenancy proof: a SECOND GPU-requesting pod schedules to Running while the
#         baseline vLLM already holds a slice — i.e. two pods truly share one card.
gpu_cotenant() {
    kubectl delete pod gpu-cotenant-probe -n "$STUDENT_NS" --ignore-not-found >/dev/null 2>&1
    kubectl run gpu-cotenant-probe -n "$STUDENT_NS" --image=busybox:1.36 --restart=Never \
        --overrides='{"spec":{"containers":[{"name":"p","image":"busybox:1.36","command":["sh","-c","sleep 180"],"resources":{"limits":{"nvidia.com/gpu":"1"}}}]}}' >/dev/null 2>&1 || return 1
    local ok=1 phase
    for _ in $(seq 1 20); do
        phase=$(kubectl get pod gpu-cotenant-probe -n "$STUDENT_NS" -o jsonpath='{.status.phase}' 2>/dev/null)
        [ "$phase" = "Running" ] && { ok=0; break; }
        sleep 3
    done
    kubectl delete pod gpu-cotenant-probe -n "$STUDENT_NS" --ignore-not-found >/dev/null 2>&1
    return $ok
}
if [ "$GPU_SHARING" = "timeslicing" ]; then
    assert "two pods co-schedule on one time-sliced GPU (2nd pod reaches Running)" gpu_cotenant
fi

# 2b. Per-student dedicated vLLM (Deployment, in the student namespace) Ready + /health 200.
assert "per-student vLLM Deployment Ready (workshop-s01)" \
    kubectl -n "$STUDENT_NS" rollout status deployment/vllm --timeout=600s
assert "per-student vLLM /health returns 200" \
    kubectl -n "$STUDENT_NS" exec deploy/vllm -- \
      curl -sf -o /dev/null -w '%{http_code}' http://localhost:8000/health

# 2c. A chat completion returns non-empty text (via the per-student vLLM itself).
chat_ok() {
    local out
    out=$(kubectl -n "$STUDENT_NS" exec deploy/vllm -- curl -sf \
        http://localhost:8000/v1/chat/completions \
        -H 'Content-Type: application/json' \
        -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hi in one word.\"}],\"max_tokens\":16}")
    echo "$out" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d['choices'][0]['message']['content'].strip() else 1)"
}
assert "per-student vLLM chat completion returns text" chat_ok

# 2d. Student workspace Ready (in the per-student namespace).
assert "workspace ws-01 Ready (workshop-s01)" \
    kubectl -n "$STUDENT_NS" wait --for=condition=Ready pod/ws-01 --timeout=300s

# 2d-bis. Workshop content actually cloned (a REAL checkout, not a bare .git left by a
#         failed clone). Ready does not gate on clone completion, so poll for ~120s.
content_cloned() {
    for _ in $(seq 1 24); do
        if kubectl -n "$STUDENT_NS" exec ws-01 -- bash -lc \
              'git -C "${HOME}/workshop" rev-parse --verify HEAD >/dev/null 2>&1 \
               && [ -n "$(ls -A "${HOME}/workshop" 2>/dev/null | grep -v "^\.git$")" ]'; then
            return 0
        fi
        sleep 5
    done
    return 1
}
assert "workshop content cloned into ws-01 (real checkout)" content_cloned

# 2e. https://s01.<base_host>/ serves Jupyter (editor=jupyter), not code-server.
jupyter_page_ok() {
    local body
    # Jupyter Lab redirects to /lab and serves a token login page; match either.
    body=$(curl -k -sL --max-time 30 "https://s01.${BASE_HOST}/")
    echo "$body" | grep -qiE "jupyter|/lab|token"
}
assert "s01 serves Jupyter (HTTPS, self-signed)" jupyter_page_ok

# 2f. From INSIDE the workspace pod, reach the in-namespace dedicated vLLM (NetworkPolicy).
student_to_vllm() {
    local out
    out=$(kubectl -n "$STUDENT_NS" exec ws-01 -- curl -sf \
        http://vllm:8000/v1/chat/completions \
        -H 'Content-Type: application/json' \
        -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":8}")
    echo "$out" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d['choices'][0]['message']['content'] is not None else 1)"
}
assert "student workspace → in-namespace vLLM path (NetworkPolicy)" student_to_vllm

# 2g. Scoped kubeconfig isolation (cluster_access=scoped). The in-pod kubeconfig is the
#     student SA, fenced to its own namespace: own-namespace reads work; cluster-scoped
#     (nodes) and other namespaces (kube-system) are Forbidden.
scoped_kubeconfig_fenced() {
    # Allowed: list pods in the student's own namespace.
    kubectl -n "$STUDENT_NS" exec ws-01 -- kubectl get pods >/dev/null 2>&1 || return 1
    # Forbidden: cluster-scoped nodes.
    if kubectl -n "$STUDENT_NS" exec ws-01 -- kubectl get nodes >/dev/null 2>&1; then
        return 1
    fi
    # Forbidden: another namespace (kube-system).
    if kubectl -n "$STUDENT_NS" exec ws-01 -- kubectl -n kube-system get pods >/dev/null 2>&1; then
        return 1
    fi
    return 0
}
assert "scoped kubeconfig fenced (own ns OK; nodes + kube-system Forbidden)" scoped_kubeconfig_fenced

# 2h. capacity-test emits a students-per-replica number (against the per-student vLLM).
CAP_RESULT="(not run)"
capacity_ok() {
    local log
    log=$("${SCRIPT_DIR}/capacity-test.sh" --model "$MODEL" --namespace "$STUDENT_NS" \
        --levels "1 4 8" --num-prompts 16 --students 1 2>&1)
    CAP_RESULT=$(echo "$log" | grep -E 'CAPACITY_RESULT|enrolled per replica' | tail -1)
    echo "$log" | grep -q "CAPACITY_RESULT"
}
assert "capacity-test emits a result" capacity_ok

# ---------------------------------------------------------------------------
# 3. Record results (teardown happens in the trap after this).
# ---------------------------------------------------------------------------
END_TS="$(date +%s)"
TOTAL_MIN=$(( (END_TS - START_TS) / 60 ))
note "--- results: ${PASSES} passed, ${FAILURES} failed ---"
{
    echo "# e2e smoke results"
    echo ""
    echo "- region: ${REGION}"
    echo "- model: ${MODEL}"
    echo "- footprint: 1× g2-gpu-rtx4000a1-s (TP=1) + 1× g6-standard-4, 1 student, no domain"
    echo "- composition: editor=jupyter, inference=dedicated-vllm (1 GPU), cluster_access=scoped"
    echo "- cold start (deploy→ready): ~${COLD_START_MIN} min"
    echo "- total runtime (incl. teardown follows): ~${TOTAL_MIN} min"
    echo "- result: ${PASSES} passed, ${FAILURES} failed"
    echo "- capacity: ${CAP_RESULT}"
    echo ""
    echo "## checks"
    for r in "${RESULTS[@]}"; do echo "- ${r}"; done
} > "$RESULTS_MD"
note "wrote ${RESULTS_MD}"

[ "$FAILURES" -eq 0 ] && note "SMOKE TEST PASSED" || note "SMOKE TEST FAILED (${FAILURES})"
# Teardown runs now via the EXIT trap. Exit code reflects assertion outcome.
exit "$([ "$FAILURES" -eq 0 ] && echo 0 || echo 1)"
