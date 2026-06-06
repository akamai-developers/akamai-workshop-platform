#!/usr/bin/env bash
set -euo pipefail

# Empirical capacity test: ramp concurrency against a running vLLM replica and
# report students-per-replica at a p99 latency threshold. Generalizes the old
# load-test. Runs against the cluster in infra/kubeconfig.yaml (i.e. deploy first,
# or point at a cheap single-GPU probe). It deploys NO cloud infrastructure itself.
#
# Usage:
#   ./capacity-test.sh                                   # generic profile, default ramp
#   ./capacity-test.sh --model Qwen/Qwen3-8B-FP8 --levels "1 4 8 16 32 64 128"
#   ./capacity-test.sh --profile workshop --content-repo https://github.com/org/repo
#   ./capacity-test.sh --threshold 8000 --num-prompts 128
#
# Output ends with a CAPACITY_RESULT line and a suggested replica count for a class:
#   feed enrolled_per_replica back into sizing (replicas = ceil(students / that)).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
KUBECONFIG_PATH="${INFRA_DIR}/kubeconfig.yaml"
JOB_MANIFEST="${INFRA_DIR}/manifests/capacity-test-job.yaml"
NAMESPACE="${NAMESPACE:-workshop}"

MODEL="${MODEL:-Qwen/Qwen3-8B-FP8}"
LEVELS="${CONCURRENCY_LEVELS:-1 4 8 16 32 64}"
NUM_PROMPTS="${NUM_PROMPTS:-64}"
THRESHOLD="${P99_THRESHOLD_MS:-10000}"
PROFILE="${PROFILE:-generic}"
CONTENT_REPO="${CONTENT_REPO:-}"
STUDENTS="${STUDENTS:-}"      # optional: print a recommended replica count for this class
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model)        MODEL="$2"; shift 2 ;;
        --levels)       LEVELS="$2"; shift 2 ;;
        --num-prompts)  NUM_PROMPTS="$2"; shift 2 ;;
        --threshold)    THRESHOLD="$2"; shift 2 ;;
        --profile)      PROFILE="$2"; shift 2 ;;
        --content-repo) CONTENT_REPO="$2"; shift 2 ;;
        --namespace)    NAMESPACE="$2"; shift 2 ;;
        --students)     STUDENTS="$2"; shift 2 ;;
        --region)       shift 2 ;;   # accepted for wizard compatibility; unused here
        --dry-run)      DRY_RUN=1; shift ;;
        -h|--help)      sed -n '3,20p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# --dry-run: render the Job with overrides applied and print it (no cluster needed).
render_job() {
    python3 - "$JOB_MANIFEST" "$MODEL" "$LEVELS" "$NUM_PROMPTS" "$THRESHOLD" "$PROFILE" "$CONTENT_REPO" "$NAMESPACE" <<'PY'
import sys
path,model,levels,nump,thr,profile,repo,ns = sys.argv[1:9]
text=open(path).read()
# Patch the env defaults + namespace so the rendered Job reflects the run.
import re
text=text.replace("namespace: workshop", f"namespace: {ns}")
def setenv(t,name,val):
    return re.sub(rf'(- name: {name}\n              value: ")[^"]*(")', rf'\g<1>{val}\g<2>', t)
text=setenv(text,"MODEL",model)
text=setenv(text,"CONCURRENCY_LEVELS",levels)
text=setenv(text,"NUM_PROMPTS",nump)
text=setenv(text,"P99_THRESHOLD_MS",thr)
text=setenv(text,"PROFILE",profile)
print(text)
PY
}

if [[ $DRY_RUN -eq 1 ]]; then
    echo "=== capacity-test Job (dry-run render) ==="
    render_job
    exit 0
fi

if [ ! -s "${KUBECONFIG_PATH}" ]; then
    echo "ERROR: no kubeconfig at ${KUBECONFIG_PATH}." >&2
    echo "  Deploy first (./deploy.sh) or provision a single-GPU probe, then re-run." >&2
    exit 1
fi
export KUBECONFIG="${KUBECONFIG_PATH}"

echo "=== capacity test ==="
echo "  model:       ${MODEL}"
echo "  profile:     ${PROFILE}"
echo "  levels:      ${LEVELS}"
echo "  p99 thresh:  ${THRESHOLD} ms"
echo "  namespace:   ${NAMESPACE}"
echo ""

kubectl -n "${NAMESPACE}" delete job vllm-capacity-test --ignore-not-found
kubectl -n "${NAMESPACE}" apply -f "${JOB_MANIFEST}"
kubectl -n "${NAMESPACE}" set env job/vllm-capacity-test \
    MODEL="${MODEL}" CONCURRENCY_LEVELS="${LEVELS}" NUM_PROMPTS="${NUM_PROMPTS}" \
    P99_THRESHOLD_MS="${THRESHOLD}" PROFILE="${PROFILE}" CONTENT_REPO="${CONTENT_REPO}"

echo "Waiting for pod…"
kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod -l app=capacity-test --timeout=180s 2>/dev/null || true
POD=$(kubectl -n "${NAMESPACE}" get pods -l app=capacity-test -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -z "${POD}" ] && { echo "ERROR: capacity-test pod did not start." >&2; exit 1; }

# Stream logs and capture them to parse the result line.
LOG="$(mktemp -t capacity-test.XXXXXX.log)"
trap 'rm -f "${LOG}"' EXIT
kubectl -n "${NAMESPACE}" logs -f "${POD}" | tee "${LOG}"

RESULT_LINE="$(grep -E '^CAPACITY_RESULT ' "${LOG}" | tail -1 || true)"
echo ""
if [ -z "${RESULT_LINE}" ]; then
    echo "=== No CAPACITY_RESULT produced (vLLM unreachable or job failed). ==="
    kubectl -n "${NAMESPACE}" get job vllm-capacity-test
    exit 1
fi

ENROLLED="$(echo "${RESULT_LINE}" | sed -E 's/.*enrolled_per_replica=([0-9]+).*/\1/')"
ACTIVE="$(echo "${RESULT_LINE}" | sed -E 's/.*active_per_replica=([0-9]+).*/\1/')"
echo "=== Capacity result ==="
echo "  active students per replica (under p99 ${THRESHOLD}ms): ${ACTIVE}"
echo "  enrolled students per replica (≈2.5× active):           ${ENROLLED}"
if [ -n "${STUDENTS}" ] && [ "${ENROLLED}" -gt 0 ] 2>/dev/null; then
    REPLICAS=$(( (STUDENTS + ENROLLED - 1) / ENROLLED ))
    echo "  → for ${STUDENTS} students: ${REPLICAS} replica(s) (= ceil(${STUDENTS}/${ENROLLED}))"
    echo "    re-run deploy with --gpu-node-count ${REPLICAS} to use this measured number."
fi
