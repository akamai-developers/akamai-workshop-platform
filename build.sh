#!/bin/bash
# Autonomous multi-session build runner for akamai-workshop-platform.
# Usage: ./build.sh
#
# Runs Claude Code in a loop; each run reads PROMPT.md and continues from
# BUILD_PROGRESS.md. Phases 1-7 are code-only. Phase 8 deploys REAL Akamai
# infrastructure that bills by the hour, then tears it down.

set -u
cd "$(dirname "$(readlink -f "$0")")"

MAX_RUNS=11          # 8 phases + 3 for retries/polish
RUN=0
LOG_DIR="build-logs"
E2E_LABEL="awp-e2e-smoke"
mkdir -p "$LOG_DIR"

# Map LINODE_TOKEN -> TF_VAR_token so Terraform + Phase 8 can authenticate.
if [ -z "${TF_VAR_token:-}" ] && [ -n "${LINODE_TOKEN:-}" ]; then
    export TF_VAR_token="$LINODE_TOKEN"
fi

# ---- Safety net: if the loop EVER exits while the e2e smoke cluster is still
# ---- alive (crash, Ctrl-C, max-runs), destroy it so it cannot bill forever.
safety_teardown() {
    if command -v linode-cli >/dev/null 2>&1 && [ -n "${TF_VAR_token:-}" ]; then
        local leftover
        leftover=$(linode-cli lke clusters-list --json 2>/dev/null \
            | python3 -c "import sys,json;print('\n'.join(c['label'] for c in json.load(sys.stdin) if c.get('label')=='$E2E_LABEL'))" 2>/dev/null || true)
        if [ -n "$leftover" ]; then
            echo ""
            echo "!!! SAFETY TEARDOWN: e2e cluster '$E2E_LABEL' still exists — destroying."
            if [ -d infra/terraform ]; then (cd infra/terraform && terraform destroy -auto-approve 2>&1 | tail -20); fi
            local cid
            cid=$(linode-cli lke clusters-list --json 2>/dev/null \
                | python3 -c "import sys,json;[print(c['id']) for c in json.load(sys.stdin) if c.get('label')=='$E2E_LABEL']" 2>/dev/null || true)
            [ -n "$cid" ] && linode-cli lke cluster-delete "$cid" 2>/dev/null || true
            echo "!!! Verify manually: linode-cli lke clusters-list"
        fi
    fi
}
trap safety_teardown EXIT

echo "============================================"
echo "  Autonomous Build — akamai-workshop-platform"
echo "============================================"
echo "Max runs : $MAX_RUNS"
echo "Logs     : $LOG_DIR/"
echo "Started  : $(date)"
if [ -n "${TF_VAR_token:-}" ]; then
    echo "Linode   : token present — Phase 8 WILL deploy + test on real LKE, then tear down."
    echo ""
    echo "  ⚠  Phase 8 provisions billable GPU infra (smoke test ≈ \$0.52/hr GPU + a"
    echo "     NodeBalancer + a small CPU node, torn down automatically). Expect ~\$1-3 total"
    echo "     if teardown succeeds. A safety-net teardown also runs when this script exits."
else
    echo "Linode   : NO token (set TF_VAR_token or LINODE_TOKEN) — Phases 1-7 only;"
    echo "           Phase 8 will write a BLOCKED note instead of deploying."
fi
echo "============================================"
echo ""

while [ $RUN -lt $MAX_RUNS ]; do
    RUN=$((RUN + 1))
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    LOG_FILE="$LOG_DIR/run_${RUN}_${TIMESTAMP}.log"

    echo ">>> Run $RUN/$MAX_RUNS - $(date)"
    echo ">>> Log: $LOG_FILE"
    echo ""

    cat PROMPT.md | claude --dangerously-skip-permissions --verbose 2>&1 | tee "$LOG_FILE"

    EXIT_CODE=${PIPESTATUS[1]}
    echo ""
    echo ">>> Run $RUN finished with exit code $EXIT_CODE at $(date)"
    echo ""

    # If the build signalled completion, stop early.
    if grep -qi "ALL 8 PHASES.*DONE\|BUILD COMPLETE" BUILD_PROGRESS.md 2>/dev/null; then
        echo ">>> BUILD_PROGRESS.md reports completion — stopping the loop."
        break
    fi

    sleep 5
done

echo "============================================"
echo "  Build loop finished - $RUN run(s)"
echo "  $(date)"
echo "============================================"
# safety_teardown runs here via the EXIT trap.
