#!/usr/bin/env bash
set -euo pipefail

# akamai-workshop-platform — deploy wizard.
#
# Two verbs:
#   ./deploy.sh [deploy]          provision a classroom (interactive by default)
#   ./deploy.sh teardown          destroy everything
#   ./deploy.sh capacity-test     measure students-per-replica for a model (Phase 6)
#
# Answer ~5 questions (students / model / content repo / domain / region), see a
# cost + sizing preview, confirm once, and get a running classroom + access-cards.csv.
#
# Non-interactive (for CI / the e2e smoke test):
#   ./deploy.sh --yes --config config.yaml
#   ./deploy.sh --yes --students 1 --model Qwen/Qwen3-4B-Instruct-2507 \
#               --gpu-node-type g2-gpu-rtx4000a1-s --tp 1 --domain ""
#
# Dry run (no cloud resources, no files written):
#   ./deploy.sh --dry-run --students 80 --model Qwen/Qwen3-8B-FP8
#
# The Linode token is read from $TF_VAR_token or $LINODE_TOKEN — never from a file
# the wizard writes, and never committed.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA="${ROOT_DIR}/infra"
SCRIPTS="${INFRA}/scripts"
TF_DIR="${INFRA}/terraform"
GEN_DIR="${INFRA}/manifests/generated"
HELM_VALUES_OUT="${INFRA}/manifests/helm-values.yaml"
TFVARS_OUT="${TF_DIR}/terraform.tfvars"

# ---------------------------------------------------------------------------
# Defaults (config.yaml < flags). Empty string is a meaningful value (domain="").
# ---------------------------------------------------------------------------
STUDENTS=""
MODEL=""
CONTENT_REPO=""
DOMAIN=""
REGION=""
# Advanced / sizing overrides (autopilot fills these when left empty).
GPU_NODE_TYPE=""
GPU_NODE_COUNT=""
TP=""
CPU_NODE_TYPE=""
CPU_NODE_COUNT=""
# Cluster / TLS knobs.
LABEL=""                      # deployment name (Linode cluster label); default applied below
K8S_VERSION="1.34"
SUBDOMAIN_PREFIX="workshop"
CERT_EMAIL=""
ALLOWED_CIDR="0.0.0.0/0"
NAMESPACE="workshop"
# Workspace / vLLM knobs.
WORKSPACE_IMAGE="codercom/code-server:latest"
MAX_MODEL_LEN="32768"
GPU_MEMORY_UTIL="0.9"

ASSUME_YES=0
DRY_RUN=0
CONFIG=""
VERB="deploy"

# ---------------------------------------------------------------------------
# Formatting helpers (ANSI; degrades to plain text when not a TTY or NO_COLOR)
# ---------------------------------------------------------------------------
if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]] && [[ -z "${NO_COLOR:-}" ]]; then
    BOLD=$'\033[1m'  DIM=$'\033[2m'  RESET=$'\033[0m'
    GREEN=$'\033[32m'  YELLOW=$'\033[33m'  RED=$'\033[31m'  CYAN=$'\033[36m'
else
    BOLD=""  DIM=""  RESET=""
    GREEN=""  YELLOW=""  RED=""  CYAN=""
fi

err()  { printf '%b\n' "${RED}${BOLD}ERROR:${RESET} $*" >&2; exit 1; }
warn() { printf '%b\n' "${YELLOW}WARNING:${RESET} $*" >&2; }
info() { echo "$*"; }
ok()   { printf '%b\n' "  ${GREEN}✓${RESET} $*"; }
rule() { printf '%b\n' "  ${DIM}────────────────────────────────────────────────────────────${RESET}"; }

step_header() {
    local n="$1" total="$2" title="$3"
    echo ""
    printf '%b\n' "  ${CYAN}${BOLD}[$n/$total]${RESET} ${BOLD}${title}${RESET}"
}

prompt_input() {
    local label="$1" default="$2" var="$3"
    local display_default="${default}"
    [[ -z "$display_default" ]] && display_default="none"
    printf '%b' "        ${BOLD}${label}${RESET} ${DIM}[${display_default}]${RESET} "
    read -r REPLY
    eval "$var=\"\${REPLY:-$default}\""
}

field_line() {
    printf '%b\n' "  ${DIM}%-14s${RESET} %s" "$1:" "$2"
}

# Turn a human deployment name into a valid Linode label + k8s-safe slug:
# lowercase, runs of non-alphanumerics become a single hyphen, trimmed, length-capped.
slugify() {
    printf '%s' "$1" | tr 'A-Z' 'a-z' \
      | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-40
}

# List Linode domains (best-effort; token may not be set yet).
_list_linode_domains() {
    local token="${TF_VAR_token:-${LINODE_TOKEN:-}}"
    if [[ -z "$token" ]]; then
        warn "Set TF_VAR_token or LINODE_TOKEN to list your domains."
        return 0
    fi
    printf '%b\n' "  ${DIM}Fetching domains from your Linode account...${RESET}"
    local rows
    rows="$(python3 - "$token" <<'PY'
import json, sys, urllib.request, urllib.error
token = sys.argv[1]
out = []
page = 1
while True:
    url = f"https://api.linode.com/v4/domains?page={page}&page_size=100"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            d = json.load(r)
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            print("__AUTH_FAIL__")
        sys.exit(0)
    except Exception:
        sys.exit(0)
    for dom in d.get("data", []):
        out.append((dom.get("domain", ""), dom.get("type", ""), dom.get("status", "")))
    if page >= d.get("pages", 1):
        break
    page += 1
for domain, dtype, status in sorted(out):
    print(f"{domain}\t{dtype}\t{status}")
PY
)"
    if [[ "$rows" == "__AUTH_FAIL__" ]]; then
        warn "Linode token rejected. Check \$TF_VAR_token or \$LINODE_TOKEN."
        return 0
    fi
    if [[ -z "$rows" ]]; then
        printf '%b\n' "  ${DIM}(no domains found in this account)${RESET}"
    else
        echo ""
        printf "  ${DIM}%-35s %-10s %s${RESET}\n" "DOMAIN" "TYPE" "STATUS"
        echo ""
        printf '%s\n' "$rows" | while IFS=$'\t' read -r dom dtype status; do
            printf "  %-35s %-10s %s\n" "$dom" "$dtype" "$status"
        done
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Parse verb (first bare word) + flags.
# ---------------------------------------------------------------------------
if [[ $# -gt 0 && "$1" != -* ]]; then
    case "$1" in
        deploy|teardown|capacity-test) VERB="$1"; shift ;;
        *) err "unknown verb '$1' (use: deploy | teardown | capacity-test)" ;;
    esac
fi

# capacity-test has its own flag set — hand the remaining args straight to its
# script (added in Phase 6) instead of running them through the deploy parser.
if [[ "$VERB" == "capacity-test" ]]; then
    if [[ -x "${SCRIPTS}/capacity-test.sh" ]]; then
        exec "${SCRIPTS}/capacity-test.sh" "$@"
    fi
    err "capacity-test.sh not present yet (added in Phase 6)."
fi

# Pre-scan for --config so config values form the base that flags override.
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
    if [[ "${args[$i]}" == "--config" ]]; then CONFIG="${args[$((i+1))]:-}"; fi
done

load_config() {
    [[ -f "$1" ]] || err "config file not found: $1"
    # Flat key: value YAML, stdlib only. Emits shell assignments for known keys.
    local assigns
    assigns="$(python3 - "$1" <<'PY'
import sys, re
keys = {
 "students":"STUDENTS","model":"MODEL","content_repo":"CONTENT_REPO","domain":"DOMAIN",
 "region":"REGION","gpu_node_type":"GPU_NODE_TYPE","gpu_node_count":"GPU_NODE_COUNT",
 "tensor_parallel_size":"TP","cpu_node_type":"CPU_NODE_TYPE","cpu_node_count":"CPU_NODE_COUNT",
 "label":"LABEL","k8s_version":"K8S_VERSION","subdomain_prefix":"SUBDOMAIN_PREFIX",
 "cert_email":"CERT_EMAIL","allowed_cidr":"ALLOWED_CIDR","namespace":"NAMESPACE",
 "workspace_image":"WORKSPACE_IMAGE","max_model_len":"MAX_MODEL_LEN","gpu_memory_util":"GPU_MEMORY_UTIL",
}
for raw in open(sys.argv[1]):
    line = raw.split("#",1)[0].rstrip()
    m = re.match(r'^([A-Za-z0-9_]+)\s*:\s*(.*)$', line)
    if not m: continue
    k, v = m.group(1), m.group(2).strip()
    if k not in keys: continue
    if len(v) >= 2 and v[0] in "\"'" and v[-1] == v[0]:
        v = v[1:-1]
    v = v.replace("'", "'\\''")
    print(f"{keys[k]}='{v}'")
PY
)"
    eval "$assigns"
}

[[ -n "$CONFIG" ]] && load_config "$CONFIG"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)            shift 2 ;;  # already handled
        --students)          STUDENTS="$2"; shift 2 ;;
        --model)             MODEL="$2"; shift 2 ;;
        --content-repo)      CONTENT_REPO="$2"; shift 2 ;;
        --domain)            DOMAIN="$2"; shift 2 ;;
        --region)            REGION="$2"; shift 2 ;;
        --gpu-node-type)     GPU_NODE_TYPE="$2"; shift 2 ;;
        --gpu-node-count)    GPU_NODE_COUNT="$2"; shift 2 ;;
        --tp)                TP="$2"; shift 2 ;;
        --cpu-node-type)     CPU_NODE_TYPE="$2"; shift 2 ;;
        --cpu-node-count)    CPU_NODE_COUNT="$2"; shift 2 ;;
        --name|--label)      LABEL="$2"; shift 2 ;;
        --k8s-version)       K8S_VERSION="$2"; shift 2 ;;
        --subdomain-prefix)  SUBDOMAIN_PREFIX="$2"; shift 2 ;;
        --cert-email)        CERT_EMAIL="$2"; shift 2 ;;
        --allowed-cidr)      ALLOWED_CIDR="$2"; shift 2 ;;
        --namespace)         NAMESPACE="$2"; shift 2 ;;
        --workspace-image)   WORKSPACE_IMAGE="$2"; shift 2 ;;
        --max-model-len)     MAX_MODEL_LEN="$2"; shift 2 ;;
        --gpu-memory-util)   GPU_MEMORY_UTIL="$2"; shift 2 ;;
        -y|--yes)            ASSUME_YES=1; shift ;;
        --dry-run)           DRY_RUN=1; shift ;;
        --list-models)       python3 "${SCRIPTS}/sizing.py" catalog; exit 0 ;;
        -h|--help)           sed -n '3,40p' "$0"; exit 0 ;;
        *) err "unknown flag '$1' (try --help)" ;;
    esac
done

# ===========================================================================
# teardown verb — delegate to the infra teardown (headless when --yes).
# ===========================================================================
if [[ "$VERB" == "teardown" ]]; then
    exec env NAMESPACE="$NAMESPACE" AWP_ASSUME_YES="$ASSUME_YES" \
        "${SCRIPTS}/teardown.sh"
fi

# ===========================================================================
# deploy verb
# ===========================================================================
interactive() { [[ $ASSUME_YES -eq 0 && $DRY_RUN -eq 0 && -t 0 ]]; }

TOTAL_STEPS=6

# ---- Collect inputs (prompt only when interactive and unset) ----
if interactive; then
    echo ""
    rule
    printf '%b\n' "  ${BOLD}akamai-workshop-platform${RESET} ${DIM}deploy wizard${RESET}"
    rule

    # -- Step 1: Deployment name --
    if [[ -z "$LABEL" ]]; then
        step_header 1 $TOTAL_STEPS "Deployment name"
        prompt_input "Name" "ai-agents-workshop" LABEL
    else
        step_header 1 $TOTAL_STEPS "Deployment name"
        ok "pre-set: ${LABEL}"
    fi

    # -- Step 2: Class size --
    if [[ -z "$STUDENTS" ]]; then
        step_header 2 $TOTAL_STEPS "Class size"
        prompt_input "How many students" "80" STUDENTS
    else
        step_header 2 $TOTAL_STEPS "Class size"
        ok "pre-set: ${STUDENTS} students"
    fi

    # -- Step 3: Model selection --
    step_header 3 $TOTAL_STEPS "Model selection"
    if [[ -z "$MODEL" ]]; then
        printf '%b\n' "        ${DIM}Type 'list' to see the ungated model catalog${RESET}"
        while true; do
            prompt_input "Model" "Qwen/Qwen3-8B-FP8" MODEL
            case "$(printf '%s' "$MODEL" | tr 'A-Z' 'a-z')" in
                '?'|l|ls|list)
                    echo ""
                    python3 "${SCRIPTS}/sizing.py" catalog
                    echo ""
                    MODEL="" ;;
                *) break ;;
            esac
        done
    else
        ok "pre-set: ${MODEL}"
    fi

    # -- Step 4: Workshop content --
    if [[ -z "$CONTENT_REPO" ]]; then
        step_header 4 $TOTAL_STEPS "Workshop content"
        prompt_input "Content repo" "ai-agents-workshop" CONTENT_REPO
    else
        step_header 4 $TOTAL_STEPS "Workshop content"
        ok "pre-set: ${CONTENT_REPO}"
    fi

    # -- Step 5: Domain & TLS --
    step_header 5 $TOTAL_STEPS "Domain & TLS"
    if [[ -z "$DOMAIN" ]]; then
        printf '%b\n' "        ${DIM}Leave blank for sslip.io + self-signed TLS${RESET}"
        printf '%b\n' "        ${DIM}Type 'list' to see domains in your Linode account${RESET}"
        while true; do
            prompt_input "Domain" "none" DOMAIN
            case "$(printf '%s' "$DOMAIN" | tr 'A-Z' 'a-z')" in
                '?'|l|ls|list)
                    _list_linode_domains
                    DOMAIN="" ;;
                yes|y)
                    printf '%b' "        ${BOLD}Base domain${RESET} ${DIM}(e.g. example.com)${RESET} "
                    read -r DOMAIN
                    break ;;
                none) DOMAIN=""; break ;;
                *) break ;;
            esac
        done
    else
        ok "pre-set: ${DOMAIN}"
    fi

    # -- Step 6: Region --
    step_header 6 $TOTAL_STEPS "Region"
    if [[ -z "$REGION" ]]; then
        printf '%b\n' "        ${DIM}Discovering GPU-capable regions...${RESET}"
        echo ""
        "${SCRIPTS}/regions.sh" list 2>/dev/null || true
        prompt_input "Region" "us-ord" REGION
    else
        ok "pre-set: ${REGION}"
    fi
fi

# ---- Defaults for anything still empty ----
STUDENTS="${STUDENTS:-80}"
MODEL="${MODEL:-Qwen/Qwen3-8B-FP8}"
REGION="${REGION:-us-ord}"

# Sanitize the deployment name into a valid Linode label; fall back to the default.
LABEL="$(slugify "$LABEL")"
[[ -z "$LABEL" ]] && LABEL="ai-agents-workshop"

[[ "$STUDENTS" =~ ^[0-9]+$ ]] || err "students must be a positive integer (got '$STUDENTS')"

# A domain answer of no/none/false (any case) means "no domain", same as blank.
# Without this, "no" becomes a literal hostname (e.g. workshop.no) and silently
# switches on Linode DNS + Let's Encrypt. Applies to the prompt, --domain, and config.
case "$(printf '%s' "$DOMAIN" | tr 'A-Z' 'a-z')" in
    no|n|none|false|off) DOMAIN="" ;;
esac

# ---- Sizing (autopilot + any explicit overrides) ----
SIZING_ARGS=(plan --students "$STUDENTS" --model "$MODEL" --json)
[[ -n "$GPU_NODE_TYPE" ]] && SIZING_ARGS+=(--gpu-node-type "$GPU_NODE_TYPE")
[[ -n "$TP" ]]            && SIZING_ARGS+=(--tp "$TP")
[[ -n "$CPU_NODE_TYPE" ]] && SIZING_ARGS+=(--cpu-node-type "$CPU_NODE_TYPE")

PLAN_JSON="$(python3 "${SCRIPTS}/sizing.py" "${SIZING_ARGS[@]}")" \
    || err "sizing failed (see message above)"

# Pull the resolved plan back into shell vars.
eval "$(python3 - <<PY
import json
p = json.loads('''$PLAN_JSON''')
print(f'P_GPU_TYPE={p["gpu_node_type"]}')
print(f'P_GPU_COUNT={p["gpu_node_count"]}')
print(f'P_TP={p["tensor_parallel_size"]}')
print(f'P_CPU_TYPE={p["cpu_node_type"]}')
print(f'P_CPU_COUNT={p["cpu_node_count"]}')
print(f'P_REPLICAS={p["replicas"]}')
print(f'P_HOURLY={p["hourly_usd"]}')
print(f'P_GATED={int(p["gpu_gated"])}')
PY
)"

# Explicit count overrides win over the formula (e.g. e2e pins gpu_node_count=1).
GPU_NODE_TYPE="${GPU_NODE_TYPE:-$P_GPU_TYPE}"
GPU_NODE_COUNT="${GPU_NODE_COUNT:-$P_GPU_COUNT}"
TP="${TP:-$P_TP}"
CPU_NODE_TYPE="${CPU_NODE_TYPE:-$P_CPU_TYPE}"
CPU_NODE_COUNT="${CPU_NODE_COUNT:-$P_CPU_COUNT}"
REPLICAS="$P_REPLICAS"
[[ "$GPU_NODE_COUNT" != "$P_GPU_COUNT" ]] && REPLICAS="$GPU_NODE_COUNT"

if [[ -z "$DOMAIN" ]]; then DOMAIN_MODE="sslip.io + self-signed TLS";
else DOMAIN_MODE="${SUBDOMAIN_PREFIX}.${DOMAIN} (Linode DNS + Let's Encrypt)"; fi

# ---- Preview ----
echo ""
rule
printf '%b\n' "  ${BOLD}Deployment Plan${RESET}"
rule
echo ""
python3 "${SCRIPTS}/sizing.py" plan --students "$STUDENTS" --model "$MODEL" \
    ${GPU_NODE_TYPE:+--gpu-node-type "$GPU_NODE_TYPE"} ${TP:+--tp "$TP"} \
    | sed 's/^/  /'
echo ""
rule
echo ""
printf "  ${DIM}%-14s${RESET} %s\n" "Name:"       "$LABEL"
printf "  ${DIM}%-14s${RESET} %s\n" "Region:"     "$REGION"
printf "  ${DIM}%-14s${RESET} %s\n" "TLS/DNS:"    "$DOMAIN_MODE"
printf "  ${DIM}%-14s${RESET} %s\n" "Content:"    "${CONTENT_REPO:-ai-agents-workshop (default)}"
printf "  ${DIM}%-14s${RESET} %s\n" "vLLM:"       "${REPLICAS} replica(s), ${GPU_NODE_COUNT}x ${GPU_NODE_TYPE} (TP=${TP})"
printf "  ${DIM}%-14s${RESET} %s\n" "Workspaces:" "${CPU_NODE_COUNT}x ${CPU_NODE_TYPE}"
printf "  ${DIM}%-14s${RESET} %s\n" "URLs:"       "s01..s$(printf '%02d' "$STUDENTS").<base-host>"
echo ""
[[ "$P_GATED" == "1" ]] && warn "${GPU_NODE_TYPE} is access-gated and may fail to provision."

# ---- Dry run stops here, writing nothing ----
if [[ $DRY_RUN -eq 1 ]]; then
    echo ""
    printf '%b\n' "  ${CYAN}${BOLD}DRY RUN${RESET} ${DIM}No cloud resources created, no files written.${RESET}"
    printf '%b\n' "  ${DIM}Would write:${RESET} ${TFVARS_OUT}"
    printf '%b\n' "  ${DIM}             ${HELM_VALUES_OUT}${RESET}"
    exit 0
fi

# ---- Confirm ----
if interactive; then
    rule
    echo ""
    printf '%b\n' "    ${GREEN}c${RESET}  Confirm and deploy"
    printf '%b\n' "    ${YELLOW}s${RESET}  Change sizing"
    printf '%b\n' "    ${CYAN}t${RESET}  Test capacity first"
    printf '%b\n' "    ${RED}q${RESET}  Quit"
    echo ""
    while true; do
        printf '%b' "  ${BOLD}Choose${RESET} ${DIM}[c]${RESET} "
        read -r choice
        case "${choice:-c}" in
            c|C) break ;;
            s|S)
                echo ""
                printf '%b' "  ${BOLD}Students:${RESET} "; read -r STUDENTS
                printf '%b' "  ${BOLD}Model:${RESET} "; read -r MODEL
                exec "$0" deploy --students "$STUDENTS" --model "$MODEL" \
                     --label "$LABEL" --domain "$DOMAIN" --region "$REGION" \
                     ${CONTENT_REPO:+--content-repo "$CONTENT_REPO"} ;;
            t|T) "${SCRIPTS}/capacity-test.sh" --model "$MODEL" --region "$REGION" \
                     || warn "capacity-test unavailable (added in Phase 6)" ;;
            q|Q)
                echo ""
                printf '%b\n' "  ${DIM}Aborted.${RESET}"
                exit 0 ;;
            *) printf '%b\n' "  ${DIM}Pick c, s, t, or q.${RESET}" ;;
        esac
    done
fi

# ---- Token check (only now that we're really deploying) ----
export TF_VAR_token="${TF_VAR_token:-${LINODE_TOKEN:-}}"
[[ -n "$TF_VAR_token" ]] || err "set TF_VAR_token or LINODE_TOKEN before deploying."

# Validate the token now (a quick /v4/profile GET) so an invalid or expired token
# fails fast and clear, instead of deep inside 'terraform apply'.
TOKEN_HTTP="$(python3 - "$TF_VAR_token" <<'PY'
import sys, urllib.request, urllib.error
req = urllib.request.Request("https://api.linode.com/v4/profile",
                             headers={"Authorization": "Bearer " + sys.argv[1]})
try:
    with urllib.request.urlopen(req, timeout=15) as r:
        print(getattr(r, "status", r.getcode()))
except urllib.error.HTTPError as e:
    print(e.code)
except Exception:
    print("")
PY
)"
case "$TOKEN_HTTP" in
    200) ok "Linode token valid" ;;
    401|403) err "Linode token rejected (HTTP ${TOKEN_HTTP}). Check \$TF_VAR_token or \$LINODE_TOKEN; it may be invalid or expired." ;;
    "")  warn "could not reach the Linode API to validate the token; continuing." ;;
    *)   warn "unexpected response (HTTP ${TOKEN_HTTP}) validating the token; continuing." ;;
esac

# ---- Capacity preflight (advisory; never strands a half-built cluster) ----
echo ""
rule
printf '%b\n' "  ${BOLD}GPU capacity preflight${RESET}"
rule
"${SCRIPTS}/regions.sh" preflight "$GPU_NODE_TYPE" "$REGION" || true

# ---- Write terraform.tfvars (token stays in the env, not the file) ----
mkdir -p "$GEN_DIR"
cat > "$TFVARS_OUT" <<EOF
# Generated by deploy.sh — do not commit. Token comes from \$TF_VAR_token.
region           = "${REGION}"
k8s_version      = "${K8S_VERSION}"
label            = "${LABEL}"
cpu_node_type    = "${CPU_NODE_TYPE}"
cpu_node_count   = ${CPU_NODE_COUNT}
gpu_node_type    = "${GPU_NODE_TYPE}"
gpu_node_count   = ${GPU_NODE_COUNT}
domain           = "${DOMAIN}"
subdomain_prefix = "${SUBDOMAIN_PREFIX}"
cert_email       = "${CERT_EMAIL}"
allowed_cidr     = "${ALLOWED_CIDR}"
EOF
ok "Wrote ${TFVARS_OUT}"

# ---- Write Helm overrides (merged over infra/helm/values.yaml) ----
cat > "$HELM_VALUES_OUT" <<EOF
# Generated by deploy.sh — do not commit.
namespace: ${NAMESPACE}
student_count: ${STUDENTS}
model: ${MODEL}
replicas: ${REPLICAS}
tensor_parallel_size: ${TP}
max_model_len: ${MAX_MODEL_LEN}
gpu_memory_util: ${GPU_MEMORY_UTIL}
workspace_image: ${WORKSPACE_IMAGE}
content_repo: "${CONTENT_REPO}"
hf_token: ""
EOF
ok "Wrote ${HELM_VALUES_OUT}"

# ---- Provision (terraform + helm + vLLM + TLS) ----
echo ""
rule
printf '%b\n' "  ${BOLD}Provisioning${RESET}"
rule
env NAMESPACE="$NAMESPACE" DOMAIN="$DOMAIN" HELM_VALUES="$HELM_VALUES_OUT" \
    STUDENT_COUNT="$STUDENTS" "${SCRIPTS}/provision.sh"

# ---- Base host (for student URLs) ----
BASE_HOST="$(cd "$TF_DIR" && terraform output -raw base_host)"

# ---- Generate per-student workspaces ----
echo ""
rule
printf '%b\n' "  ${BOLD}Generating ${STUDENTS} student workspaces${RESET}"
rule
env NAMESPACE="$NAMESPACE" "${SCRIPTS}/generate-pods.sh" \
    -n "$STUDENTS" --host "$BASE_HOST" \
    --namespace "$NAMESPACE" --image "$WORKSPACE_IMAGE" \
    --model "$MODEL" --content-repo "$CONTENT_REPO"

export KUBECONFIG="${INFRA}/kubeconfig.yaml"
kubectl apply -f "${GEN_DIR}/"

# ---- Done ----
CSV="${GEN_DIR}/access-cards.csv"
echo ""
rule
printf '%b\n' "  ${GREEN}${BOLD}Classroom ready${RESET}"
rule
echo ""
printf "  ${DIM}%-14s${RESET} %s\n" "Base host:"    "$BASE_HOST"
printf "  ${DIM}%-14s${RESET} %s\n" "Access cards:" "$CSV"
if [[ -f "$CSV" ]]; then
    echo ""
    head -6 "$CSV" | sed 's/^/  /'
    [[ $(wc -l <"$CSV") -gt 6 ]] && printf '%b\n' "  ${DIM}($(($(wc -l <"$CSV")-1)) students total)${RESET}"
fi
echo ""
printf "  ${DIM}%-14s${RESET} %s\n" "Print cards:" "${SCRIPTS}/print-access-cards.sh"
printf "  ${DIM}%-14s${RESET} %s\n" "Tear down:"   "./deploy.sh teardown"
echo ""
