#!/usr/bin/env bash
set -euo pipefail

# Pull the latest workshop content into every RUNNING student workspace.
#
# Why this exists: workspaces clone the content repo once at pod startup and
# startup.sh SKIPS the clone if content already exists, so a push to the content
# repo does NOT reach already-running pods. Re-running `make deploy` doesn't help
# either (the pod spec is unchanged, so kubectl apply is a no-op). This updates
# each workspace in place — no pod recreation, sessions stay up.
#
#   ./infra/scripts/refresh-content.sh                 # force every workspace to origin/main
#   ./infra/scripts/refresh-content.sh --ref my-branch # update to a different ref
#   ./infra/scripts/refresh-content.sh --keep-edits    # ff-only pull (preserve in-pod edits)
#   ./infra/scripts/refresh-content.sh --namespace workshop   # limit to one classroom

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
KUBECONFIG_PATH="${INFRA_DIR}/kubeconfig.yaml"

NAMESPACE="${NAMESPACE:-workshop}"                 # classroom base ns (workspaces live in it or its -sNN children)
CONTENT_REF="${CONTENT_REF:-main}"                 # branch/tag/sha to update to
WORKSPACE_DIR="${WORKSPACE_DIR:-/home/coder/workshop}"
KEEP_EDITS=0                                       # default: force to origin ref; --keep-edits = ff-only

while [[ $# -gt 0 ]]; do
    case "$1" in
        --namespace)  NAMESPACE="$2"; shift 2 ;;
        --ref)        CONTENT_REF="$2"; shift 2 ;;
        --keep-edits) KEEP_EDITS=1; shift ;;
        -h|--help)
            echo "usage: refresh-content.sh [--namespace BASE] [--ref BRANCH] [--keep-edits]"
            echo "  Pulls the latest content into every running student workspace."
            echo "  default     : hard-reset each workspace to origin/<ref> (discards in-pod edits)"
            echo "  --keep-edits: fast-forward only (fails on a pod with local changes)"
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

[[ -f "${KUBECONFIG_PATH}" ]] && export KUBECONFIG="${KUBECONFIG_PATH}"

# The git command run inside each workspace. WORKSPACE_DIR holds a real checkout with
# origin set (startup.sh leaves the .git in place), so fetch+checkout / pull both work.
if [[ "${KEEP_EDITS}" -eq 1 ]]; then
    GIT_CMD="cd '${WORKSPACE_DIR}' && git pull --ff-only origin '${CONTENT_REF}'"
else
    GIT_CMD="cd '${WORKSPACE_DIR}' && git fetch --depth=1 origin '${CONTENT_REF}' && git checkout -q -f FETCH_HEAD"
fi

echo "=== Refreshing workshop content to '${CONTENT_REF}' (classroom '${NAMESPACE}') ==="

LIST="$(kubectl get pods -A -l app=workspace \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"

if [[ -z "${LIST}" ]]; then
    echo "No workspace pods found. Is kubectl pointed at the workshop cluster?" >&2
    exit 1
fi

total=0; ok=0; fail=0
while IFS='/' read -r ns pod; do
    [[ -z "${ns}" || -z "${pod}" ]] && continue
    # Limit to this classroom: the base namespace or its per-student children (-sNN).
    [[ "${ns}" == "${NAMESPACE}" || "${ns}" =~ ^${NAMESPACE}-s[0-9]+$ ]] || continue
    total=$((total + 1))
    printf '  %s/%s ... ' "${ns}" "${pod}"
    if kubectl -n "${ns}" exec "${pod}" -- sh -lc "${GIT_CMD}" >/dev/null 2>&1; then
        echo "ok"; ok=$((ok + 1))
    else
        echo "FAILED (pod not ready, or local changes block ff-only)"; fail=$((fail + 1))
    fi
done <<< "${LIST}"

if [[ "${total}" -eq 0 ]]; then
    echo "No workspace pods matched classroom '${NAMESPACE}'." >&2
    exit 1
fi

echo "=== Done: ${ok}/${total} updated, ${fail} failed ==="
[[ "${fail}" -eq 0 ]]
