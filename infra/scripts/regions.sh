#!/usr/bin/env bash
set -euo pipefail

# Live GPU region discovery + capacity preflight for akamai-workshop-platform.
#
# GPUs are offered in only some Akamai regions and go out of stock, so the wizard
# never hardcodes a region — it asks the API. Both endpoints used here are PUBLIC
# (no token required):
#   GET /v4/regions               → capability "GPU Linodes" = region offers GPU
#   GET /v4/regions/availability  → live per-plan stock flags (partial; see note)
#
# Commands:
#   regions.sh list                     List GPU-capable regions (the wizard menu).
#   regions.sh availability <plan>      Per-region stock flags for a GPU plan.
#   regions.sh preflight <plan> <region>  Verdict + fallbacks for a plan/region.
#
# NOTE on ground truth: the availability feed reads available=false for essentially
# every g1/g2-gpu plan even when stock exists, so this tool is ADVISORY. The only
# real proof is a provision attempt — the wizard/e2e provisions the GPU pool first
# and tears down clean on a capacity error.

API="https://api.linode.com/v4"
# Default preference order when the wizard picks a region automatically (US-first).
PREFERRED="us-ord us-sea us-east us-lax us-mia us-southeast"

CMD="${1:-list}"

fetch() {
    # $1 = path. Uses python3 stdlib (no jq dependency).
    python3 - "$API$1" <<'PY'
import json, sys, urllib.request
url = sys.argv[1]
try:
    with urllib.request.urlopen(url, timeout=30) as r:
        data = json.load(r)
except Exception as e:
    sys.stderr.write(f"ERROR: request to {url} failed: {e}\n")
    print("{}")          # valid empty JSON so downstream parsers don't choke
    sys.exit(0)
try:
    json.dump(data, sys.stdout)
except BrokenPipeError:
    pass
PY
}

gpu_regions_json() {
    # Paginates /v4/regions and emits one "id\tlabel" line per GPU-capable region.
    python3 - <<PY
import json, sys, urllib.request
api = "${API}"
out = []
page = 1
while True:
    url = f"{api}/regions?page={page}&page_size=100"
    with urllib.request.urlopen(url, timeout=30) as r:
        d = json.load(r)
    for reg in d.get("data", []):
        if "GPU Linodes" in reg.get("capabilities", []):
            out.append((reg["id"], reg.get("label", reg["id"])))
    if page >= d.get("pages", 1):
        break
    page += 1
for rid, label in sorted(out):
    print(f"{rid}\t{label}")
PY
}

cmd_list() {
    echo "GPU-capable Akamai regions (capability \"GPU Linodes\"):"
    echo ""
    local rows
    rows="$(gpu_regions_json)"
    if [ -z "${rows}" ]; then
        echo "  (none returned — check network / API status)" >&2
        return 1
    fi
    printf '%s\n' "${rows}" | while IFS=$'\t' read -r rid label; do
        printf "  %-16s %s\n" "${rid}" "${label}"
    done
    echo ""
    # Suggest a default = first preferred region that is actually GPU-capable.
    local available_ids
    available_ids="$(printf '%s\n' "${rows}" | cut -f1)"
    for p in ${PREFERRED}; do
        if printf '%s\n' "${available_ids}" | grep -qx "${p}"; then
            echo "Suggested default: ${p}"
            return 0
        fi
    done
    echo "Suggested default: $(printf '%s\n' "${available_ids}" | head -1)"
}

cmd_availability() {
    local plan="${1:-}"
    [ -z "${plan}" ] && { echo "usage: regions.sh availability <plan>" >&2; exit 1; }
    echo "Availability feed for plan '${plan}' (advisory — see note in this script):"
    echo ""
    fetch "/regions/availability?page_size=500" | python3 - "${plan}" <<'PY'
import json, sys
plan = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    print("  (availability feed unavailable right now — advisory only.)"); sys.exit(0)
rows = [r for r in data.get("data", []) if r.get("plan") == plan]
if not rows:
    print(f"  no availability rows for plan '{plan}' (feed may not cover it).")
else:
    for r in sorted(rows, key=lambda x: x.get("region","")):
        flag = "available" if r.get("available") else "OUT OF STOCK (per feed)"
        print(f"  {r.get('region',''):16} {flag}")
PY
}

cmd_preflight() {
    local plan="${1:-}" region="${2:-}"
    if [ -z "${plan}" ] || [ -z "${region}" ]; then
        echo "usage: regions.sh preflight <plan> <region>" >&2; exit 1
    fi
    echo "=== GPU capacity preflight: ${plan} in ${region} ==="

    # 1. Is GPU even offered in this region?
    if ! gpu_regions_json | cut -f1 | grep -qx "${region}"; then
        echo "  ✗ ${region} does not offer GPU Linodes."
        echo ""
        echo "  Fallback 1 — pick a GPU-capable region. Run: regions.sh list"
        exit 1
    fi
    echo "  ✓ ${region} offers GPU Linodes."

    # 2. What does the (partial) availability feed say?
    local flag
    flag="$(fetch "/regions/availability?page_size=500" | python3 - "${plan}" "${region}" <<'PY'
import json, sys
plan, region = sys.argv[1], sys.argv[2]
try:
    data = json.load(sys.stdin)
except Exception:
    print("unknown"); sys.exit(0)
for r in data.get("data", []):
    if r.get("plan") == plan and r.get("region") == region:
        print("available" if r.get("available") else "out")
        break
else:
    print("unknown")
PY
)"
    case "${flag}" in
        available) echo "  ✓ availability feed: in stock." ;;
        out)       echo "  ! availability feed: OUT OF STOCK (feed is partial — may still provision)." ;;
        *)         echo "  ? availability feed: no data for this plan/region (feed is partial)." ;;
    esac

    echo ""
    echo "Ground truth is the provision attempt. If 'terraform apply' fails on GPU capacity:"
    echo "  1. Retry in another GPU region        (regions.sh list)"
    echo "  2. Drop to a smaller GPU plan          (e.g. a4 → a1; re-plan as more TP=1 replicas)"
    echo "  3. Request capacity from Akamai        (large classes / Blackwell):"
    echo "     ask the account team for: ${plan} × <count> in ${region}"
}

case "${CMD}" in
    list)         cmd_list ;;
    availability) shift; cmd_availability "$@" ;;
    preflight)    shift; cmd_preflight "$@" ;;
    -h|--help|help)
        grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *) echo "Unknown command: ${CMD} (try: list | availability | preflight | --help)" >&2; exit 1 ;;
esac
