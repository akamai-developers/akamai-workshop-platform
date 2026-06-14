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
MODELS=""
MULTI_MODEL=0
CONTENT_REPO=""
GATEWAY_API_KEY=""
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
# Component catalog (PLAN.md). Empty here; defaults applied after parsing so a
# config/flag can set them. Every default equals today's behavior — a deploy that
# sets none of these is byte-identical to the original platform.
EDITOR=""            # code-server (default) | jupyter
INFERENCE=""         # shared-vllm (default) | dedicated-vllm | external
GPUS_PER_STUDENT=""  # 1 (default); 2 reserved/v2
CLUSTER_ACCESS=""    # none (default) | scoped
OBJECT_STORAGE=""    # none (default) | managed
AGENT_DEPLOY=""      # none (default) | plain; kagent reserved/v2

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
 "students":"STUDENTS","model":"MODEL","models":"MODELS",
 "content_repo":"CONTENT_REPO","domain":"DOMAIN",
 "region":"REGION","gpu_node_type":"GPU_NODE_TYPE","gpu_node_count":"GPU_NODE_COUNT",
 "tensor_parallel_size":"TP","cpu_node_type":"CPU_NODE_TYPE","cpu_node_count":"CPU_NODE_COUNT",
 "label":"LABEL","k8s_version":"K8S_VERSION","subdomain_prefix":"SUBDOMAIN_PREFIX",
 "cert_email":"CERT_EMAIL","allowed_cidr":"ALLOWED_CIDR","namespace":"NAMESPACE",
 "workspace_image":"WORKSPACE_IMAGE","max_model_len":"MAX_MODEL_LEN","gpu_memory_util":"GPU_MEMORY_UTIL",
 # Component catalog (editor accepts the legacy alias workspace_type too).
 "editor":"EDITOR","workspace_type":"EDITOR","inference":"INFERENCE",
 "gpus_per_student":"GPUS_PER_STUDENT","cluster_access":"CLUSTER_ACCESS",
 "object_storage":"OBJECT_STORAGE","agent_deploy":"AGENT_DEPLOY",
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
        --model|--models)    MODELS="$2"; shift 2 ;;
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
        --editor|--workspace-type) EDITOR="$2"; shift 2 ;;
        --inference)         INFERENCE="$2"; shift 2 ;;
        --gpus-per-student)  GPUS_PER_STUDENT="$2"; shift 2 ;;
        --cluster-access)    CLUSTER_ACCESS="$2"; shift 2 ;;
        --object-storage)    OBJECT_STORAGE="$2"; shift 2 ;;
        --agent-deploy)      AGENT_DEPLOY="$2"; shift 2 ;;
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

# Seed wizard defaults from the previous deployment. terraform.tfvars survives
# teardown precisely so a re-deploy can offer the same answers back — without
# this every fresh wizard falls back to hardcoded defaults, and a silently
# renamed deployment can collide with whatever else lives in the account.
# (Flags and --config still override; --yes runs stay on documented defaults.)
_PREV_LABEL=""; _PREV_DOMAIN=""; _PREV_REGION=""
if [[ -f "$TFVARS_OUT" ]]; then
    _tfv() {
        grep -E "^[[:space:]]*$1[[:space:]]*=" "$TFVARS_OUT" 2>/dev/null \
            | head -1 | sed -nE 's/.*=[[:space:]]*"([^"]*)".*/\1/p' || true
    }
    _PREV_LABEL="$(_tfv label)"
    _PREV_DOMAIN="$(_tfv domain)"
    _PREV_REGION="$(_tfv region)"
fi

# ---- Collect inputs (prompt only when interactive and unset) ----
if interactive; then
    echo ""
    rule
    printf '%b\n' "  ${BOLD}akamai-workshop-platform${RESET} ${DIM}deploy wizard${RESET}"
    rule

    # -- Step 1: Deployment name --
    if [[ -z "$LABEL" ]]; then
        step_header 1 $TOTAL_STEPS "Deployment name"
        [[ -n "$_PREV_LABEL" ]] && printf '%b\n' "        ${DIM}Default carried over from your last deploy${RESET}"
        prompt_input "Name" "${_PREV_LABEL:-ai-agents-workshop}" LABEL
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
    if [[ -z "$MODELS" && -z "$MODEL" ]]; then
        # Get the formatted table and numbered catalog from sizing.py
        _TABLE_OUTPUT="$(python3 "${SCRIPTS}/sizing.py" wizard-table)"
        _DEFAULT_NUM="$(printf '%s\n' "$_TABLE_OUTPUT" | grep '^__DEFAULT__:' | cut -d: -f2)"
        _DEFAULT_NUM="${_DEFAULT_NUM:-3}"
        # Print the table (everything except the __DEFAULT__ line)
        echo ""
        printf '%s\n' "$_TABLE_OUTPUT" | grep -v '^__DEFAULT__:'
        echo ""

        # Numbered catalog for resolving picks
        _CATALOG="$(python3 "${SCRIPTS}/sizing.py" numbered-catalog)"
        _CATALOG_COUNT="$(printf '%s\n' "$_CATALOG" | wc -l | tr -d ' ')"

        while true; do
            printf '%b' "        ${BOLD}Select${RESET} ${DIM}[${_DEFAULT_NUM}]${RESET} "
            read -r _PICK
            _PICK="${_PICK:-${_DEFAULT_NUM}}"
            _RESOLVED=""
            _VALID=1
            IFS=',' read -ra _NUMS <<< "$_PICK"
            for _N in "${_NUMS[@]}"; do
                _N="$(printf '%s' "$_N" | tr -d ' ')"
                if ! [[ "$_N" =~ ^[0-9]+$ ]] || [[ "$_N" -lt 1 ]] || [[ "$_N" -gt "$_CATALOG_COUNT" ]]; then
                    printf '%b\n' "        ${RED}Invalid: ${_N}. Enter 1-${_CATALOG_COUNT}.${RESET}"
                    _VALID=0
                    break
                fi
                _NAME="$(printf '%s\n' "$_CATALOG" | sed -n "${_N}p" | cut -f2)"
                if [[ -n "$_RESOLVED" ]]; then
                    _RESOLVED="${_RESOLVED},${_NAME}"
                else
                    _RESOLVED="${_NAME}"
                fi
            done
            [[ "$_VALID" -eq 0 ]] && continue
            MODELS="$_RESOLVED"
            break
        done

        if [[ "$MODELS" == *","* ]]; then
            ok "$(echo "$MODELS" | tr ',' '\n' | wc -l | tr -d ' ') models selected"
        else
            ok "$MODELS"
        fi
    elif [[ -n "$MODELS" ]]; then
        ok "pre-set: ${MODELS}"
    elif [[ -n "$MODEL" ]]; then
        MODELS="$MODEL"
        ok "pre-set: ${MODEL}"
    fi

    # -- Step 4: Workshop content --
    if [[ -z "$CONTENT_REPO" ]]; then
        step_header 4 $TOTAL_STEPS "Workshop content"
        printf '%b\n' "        ${DIM}Blank = the default Akamai AI-agents workshop${RESET}"
        printf '%b\n' "        ${DIM}Or enter a git URL or owner/repo to use your own${RESET}"
        prompt_input "Content repo" "" CONTENT_REPO
    else
        step_header 4 $TOTAL_STEPS "Workshop content"
        ok "pre-set: ${CONTENT_REPO}"
    fi

    # -- Step 5: Domain & TLS --
    step_header 5 $TOTAL_STEPS "Domain & TLS"
    if [[ -z "$DOMAIN" ]]; then
        if [[ -n "$_PREV_DOMAIN" ]]; then
            printf '%b\n' "        ${DIM}Default carried over from your last deploy; type 'none' for sslip.io + self-signed TLS${RESET}"
        else
            printf '%b\n' "        ${DIM}Leave blank for sslip.io + self-signed TLS${RESET}"
        fi
        printf '%b\n' "        ${DIM}Type 'list' to see domains in your Linode account${RESET}"
        while true; do
            prompt_input "Domain" "${_PREV_DOMAIN:-none}" DOMAIN
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
        prompt_input "Region" "${_PREV_REGION:-us-ord}" REGION
    else
        ok "pre-set: ${REGION}"
    fi
fi

# ---- Defaults for anything still empty ----
STUDENTS="${STUDENTS:-80}"
# Normalize: --model sets MODELS; legacy MODEL var is an alias.
[[ -n "$MODEL" && -z "$MODELS" ]] && MODELS="$MODEL"
MODELS="${MODELS:-Qwen/Qwen3-8B-FP8}"
# Detect multi-model: if MODELS contains a comma, set MULTI_MODEL=1.
if [[ "$MODELS" == *,* ]]; then
    MULTI_MODEL=1
    # Default MODEL_NAME stamped into workspaces: prefer the catalog default
    # (Qwen3-8B — the model the workshop content is tuned for) when it's in the
    # selected set, otherwise the first model. Avoids defaulting students onto a
    # model that may need extra per-model tuning.
    if [[ ",$MODELS," == *",Qwen/Qwen3-8B-FP8,"* ]]; then
        MODEL="Qwen/Qwen3-8B-FP8"
    else
        MODEL="${MODELS%%,*}"
    fi
else
    MULTI_MODEL=0
    MODEL="$MODELS"
fi
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

# ---- Component catalog: defaults (= today's behavior) + validation ----
# Every default below is the original platform's shape, so a deploy with no
# component flags is byte-identical to today. Reserved/v2 values are rejected
# with a clear message rather than silently doing nothing.
EDITOR="${EDITOR:-code-server}"
INFERENCE="${INFERENCE:-shared-vllm}"
GPUS_PER_STUDENT="${GPUS_PER_STUDENT:-1}"
CLUSTER_ACCESS="${CLUSTER_ACCESS:-none}"
OBJECT_STORAGE="${OBJECT_STORAGE:-none}"
AGENT_DEPLOY="${AGENT_DEPLOY:-none}"

case "$EDITOR" in code-server|jupyter) ;; *) err "editor must be 'code-server' or 'jupyter' (got '$EDITOR')" ;; esac
case "$INFERENCE" in
    shared-vllm|dedicated-vllm|external) ;;
    *) err "inference must be 'shared-vllm', 'dedicated-vllm', or 'external' (got '$INFERENCE')" ;;
esac
case "$CLUSTER_ACCESS" in none|scoped) ;; *) err "cluster_access must be 'none' or 'scoped' (got '$CLUSTER_ACCESS')" ;; esac
case "$OBJECT_STORAGE" in
    none|managed) ;;
    own-account) err "object_storage 'own-account' is reserved for v2 and not implemented yet." ;;
    *) err "object_storage must be 'none' or 'managed' (got '$OBJECT_STORAGE')" ;;
esac
case "$AGENT_DEPLOY" in
    none|plain) ;;
    kagent) err "agent_deploy 'kagent' is reserved for v2 (Agent CRD + controller not built yet). Use 'plain'." ;;
    *) err "agent_deploy must be 'none' or 'plain' (got '$AGENT_DEPLOY')" ;;
esac
case "$GPUS_PER_STUDENT" in
    1) ;;
    2) err "gpus_per_student '2' is reserved for v2 (two-models + agentgateway routing). Use 1." ;;
    *) err "gpus_per_student must be 1 (got '$GPUS_PER_STUDENT')" ;;
esac
# Dependencies (PLAN.md): shipping an agent needs a namespace to ship into.
if [[ "$AGENT_DEPLOY" != "none" && "$CLUSTER_ACCESS" != "scoped" ]]; then
    err "agent_deploy='$AGENT_DEPLOY' requires cluster_access='scoped' (the agent ships into the student's namespace)."
fi

# When editor=jupyter and the operator hasn't overridden the workspace image, default
# to the Jupyter image variant (jupyterlab + kubectl baked by build-workspace-image.sh).
# code-server keeps the stock default, so the default path is unchanged.
DEFAULT_CODE_SERVER_IMAGE="codercom/code-server:latest"
DEFAULT_JUPYTER_IMAGE="ghcr.io/akamai-developers/ai-agents-workspace-jupyter:latest"
if [[ "$EDITOR" == "jupyter" && "$WORKSPACE_IMAGE" == "$DEFAULT_CODE_SERVER_IMAGE" ]]; then
    WORKSPACE_IMAGE="$DEFAULT_JUPYTER_IMAGE"
fi

# True when the requested composition differs from the default platform shape.
components_nondefault() {
    [[ "$EDITOR" != "code-server" || "$INFERENCE" != "shared-vllm" \
       || "$CLUSTER_ACCESS" != "none" || "$OBJECT_STORAGE" != "none" \
       || "$AGENT_DEPLOY" != "none" ]]
}

# ---- Sizing (autopilot + any explicit overrides) ----
if [[ $MULTI_MODEL -eq 0 ]]; then
    # Single-model path: identical to original.
    SIZING_ARGS=(plan --students "$STUDENTS" --model "$MODEL" --json)
    [[ -n "$GPU_NODE_TYPE" ]] && SIZING_ARGS+=(--gpu-node-type "$GPU_NODE_TYPE")
    [[ -n "$TP" ]]            && SIZING_ARGS+=(--tp "$TP")
    [[ -n "$CPU_NODE_TYPE" ]] && SIZING_ARGS+=(--cpu-node-type "$CPU_NODE_TYPE")

    PLAN_JSON="$(python3 "${SCRIPTS}/sizing.py" "${SIZING_ARGS[@]}")" \
        || err "sizing failed (see message above)"

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

    GPU_NODE_TYPE="${GPU_NODE_TYPE:-$P_GPU_TYPE}"
    GPU_NODE_COUNT="${GPU_NODE_COUNT:-$P_GPU_COUNT}"
    TP="${TP:-$P_TP}"
    CPU_NODE_TYPE="${CPU_NODE_TYPE:-$P_CPU_TYPE}"
    CPU_NODE_COUNT="${CPU_NODE_COUNT:-$P_CPU_COUNT}"
    REPLICAS="$P_REPLICAS"
    [[ "$GPU_NODE_COUNT" != "$P_GPU_COUNT" ]] && REPLICAS="$GPU_NODE_COUNT"
else
    # Multi-model path: call multi-plan, parse aggregate JSON.
    PLAN_JSON="$(python3 "${SCRIPTS}/sizing.py" multi-plan \
        --students "$STUDENTS" --models "$MODELS" --json)" \
        || err "sizing failed (see message above)"

    eval "$(python3 - <<PY
import json
p = json.loads('''$PLAN_JSON''')
print(f'P_CPU_TYPE={p["cpu_node_type"]}')
print(f'P_CPU_COUNT={p["cpu_node_count"]}')
print(f'P_HOURLY={p["hourly_usd"]}')
print(f'P_GATED=0')
PY
)"
    CPU_NODE_TYPE="${CPU_NODE_TYPE:-$P_CPU_TYPE}"
    CPU_NODE_COUNT="${CPU_NODE_COUNT:-$P_CPU_COUNT}"
fi

if [[ -z "$DOMAIN" ]]; then DOMAIN_MODE="sslip.io + self-signed TLS";
else DOMAIN_MODE="${SUBDOMAIN_PREFIX}.${DOMAIN} (Linode DNS + Let's Encrypt)"; fi

# ---- Preview ----
echo ""
rule
printf '%b\n' "  ${BOLD}Deployment Plan${RESET}"
rule
echo ""
if [[ $MULTI_MODEL -eq 0 ]]; then
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
else
    python3 "${SCRIPTS}/sizing.py" multi-plan --students "$STUDENTS" --models "$MODELS" \
        | sed 's/^/  /'
    echo ""
    rule
    echo ""
    printf "  ${DIM}%-14s${RESET} %s\n" "Name:"       "$LABEL"
    printf "  ${DIM}%-14s${RESET} %s\n" "Region:"     "$REGION"
    printf "  ${DIM}%-14s${RESET} %s\n" "TLS/DNS:"    "$DOMAIN_MODE"
    printf "  ${DIM}%-14s${RESET} %s\n" "Content:"    "${CONTENT_REPO:-ai-agents-workshop (default)}"
    printf "  ${DIM}%-14s${RESET} %s\n" "Routing:"    "agentgateway → ${MODELS}"
    printf "  ${DIM}%-14s${RESET} %s\n" "Workspaces:" "${CPU_NODE_COUNT}x ${CPU_NODE_TYPE}"
    printf "  ${DIM}%-14s${RESET} %s\n" "URLs:"       "s01..s$(printf '%02d' "$STUDENTS").<base-host>"
    echo ""
fi

# ---- Component composition (only when it differs from the default shape, so the
#      default deploy's preview stays byte-identical to the original platform) ----
if components_nondefault; then
    echo ""
    rule
    printf '%b\n' "  ${BOLD}Components${RESET}"
    rule
    echo ""
    printf "  ${DIM}%-14s${RESET} %s\n" "Editor:"     "$EDITOR"
    if [[ "$INFERENCE" == "dedicated-vllm" ]]; then
        printf "  ${DIM}%-14s${RESET} %s\n" "Inference:"  "dedicated-vllm (${GPUS_PER_STUDENT} GPU/student, under-tuned)"
    else
        printf "  ${DIM}%-14s${RESET} %s\n" "Inference:"  "$INFERENCE"
    fi
    printf "  ${DIM}%-14s${RESET} %s\n" "Cluster acc.:" "$CLUSTER_ACCESS"
    printf "  ${DIM}%-14s${RESET} %s\n" "Object store:" "$OBJECT_STORAGE"
    printf "  ${DIM}%-14s${RESET} %s\n" "Agent deploy:" "$AGENT_DEPLOY"
    echo ""
fi

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
                printf '%b' "  ${BOLD}Model(s):${RESET} "; read -r MODELS
                # Re-exec preserves the component composition (config-only flags the
                # wizard never prompts for) so "Change sizing" doesn't silently reset it.
                exec "$0" deploy --students "$STUDENTS" --model "$MODELS" \
                     --label "$LABEL" --domain "$DOMAIN" --region "$REGION" \
                     ${CONTENT_REPO:+--content-repo "$CONTENT_REPO"} \
                     --editor "$EDITOR" --inference "$INFERENCE" \
                     --gpus-per-student "$GPUS_PER_STUDENT" \
                     --cluster-access "$CLUSTER_ACCESS" \
                     --object-storage "$OBJECT_STORAGE" --agent-deploy "$AGENT_DEPLOY" ;;
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
# $TF_VAR_token and $LINODE_TOKEN are interchangeable. Probe each (TF_VAR_token
# first, quick /v4/profile GET) and deploy with the first one the API accepts,
# so a stale token lingering in a shell profile can't shadow a good one — the
# same contract issue-cert.sh / provision.sh / teardown.sh follow. Invalid
# tokens still fail fast and clear here, not deep inside 'terraform apply'.
[[ -n "${TF_VAR_token:-}${LINODE_TOKEN:-}" ]] || err "set TF_VAR_token or LINODE_TOKEN before deploying."

_TOKEN_PICKED=""
for _CAND_SRC in TF_VAR_token LINODE_TOKEN; do
    _CAND="${!_CAND_SRC:-}"
    [[ -n "$_CAND" ]] || continue
    TOKEN_HTTP="$(python3 - "$_CAND" <<'PY'
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
        200) ok "Linode token valid (from \$${_CAND_SRC})"; _TOKEN_PICKED="$_CAND"; break ;;
        401|403) warn "token from \$${_CAND_SRC} rejected (HTTP ${TOKEN_HTTP}); trying next source." ;;
        "")  warn "could not reach the Linode API to validate the token; continuing with \$${_CAND_SRC}."
             _TOKEN_PICKED="$_CAND"; break ;;
        *)   warn "unexpected response (HTTP ${TOKEN_HTTP}) validating \$${_CAND_SRC}; continuing with it."
             _TOKEN_PICKED="$_CAND"; break ;;
    esac
done
[[ -n "$_TOKEN_PICKED" ]] || err "the Linode API rejected every token it was given (\$TF_VAR_token, \$LINODE_TOKEN). Recreate one at https://cloud.linode.com/profile/tokens — and if your shell profile exports a stale LINODE_TOKEN, update it."
export TF_VAR_token="$_TOKEN_PICKED"

# ---- Deployment-name preflight ----
# LKE cluster and firewall labels are account-unique, and terraform 400s
# mid-apply on a collision (e.g. an old demo cluster with the same name).
# Catch it here with a clear fix — unless this directory's terraform state
# already owns that label (a normal idempotent re-deploy).
if ! grep -qs "\"label\": \"${LABEL}\"" "${TF_DIR}/terraform.tfstate"; then
    _LABEL_CLASH="$(python3 - "$TF_VAR_token" "$LABEL" <<'PY'
import json, sys, urllib.request
token, label = sys.argv[1], sys.argv[2]
def labels(url):
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return [d["label"] for d in json.load(r).get("data", [])]
    except Exception:
        return []   # advisory check: on API trouble, let terraform be the judge
out = []
if label in labels("https://api.linode.com/v4/lke/clusters?page_size=500"):
    out.append("LKE cluster")
if f"{label}-ingress" in labels("https://api.linode.com/v4/networking/firewalls?page_size=500"):
    out.append("cloud firewall")
print(", ".join(out))
PY
)"
    if [[ -n "$_LABEL_CLASH" ]]; then
        err "deployment name '${LABEL}' already exists in your account (${_LABEL_CLASH}) and is not managed by this directory's terraform state. Pick a different name (--label <name> or the Name prompt), or tear down / rename the old resources at https://cloud.linode.com/kubernetes"
    fi
fi

# ---- Capacity preflight (advisory; never strands a half-built cluster) ----
echo ""
rule
printf '%b\n' "  ${BOLD}GPU capacity preflight${RESET}"
rule
if [[ $MULTI_MODEL -eq 0 ]]; then
    "${SCRIPTS}/regions.sh" preflight "$GPU_NODE_TYPE" "$REGION" || true
else
    # Check capacity for each model's GPU type.
    python3 - <<PY | while IFS= read -r gpu_type; do
import json
p = json.loads('''$PLAN_JSON''')
seen = set()
for m in p["models"]:
    t = m["gpu_node_type"]
    if t not in seen:
        seen.add(t)
        print(t)
PY
        "${SCRIPTS}/regions.sh" preflight "$gpu_type" "$REGION" || true
    done
fi

# ---- Write terraform.tfvars (token stays in the env, not the file) ----
mkdir -p "$GEN_DIR"
if [[ $MULTI_MODEL -eq 0 ]]; then
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
else
    # Multi-model: emit gpu_pools list from the multi-plan JSON.
    GPU_POOLS_HCL="$(python3 - <<PY
import json
p = json.loads('''$PLAN_JSON''')
lines = []
for m in p["models"]:
    lines.append('  { type = "%s", count = %d, label = "%s" }' % (
        m["gpu_node_type"], m["gpu_node_count"], m["gpu_pool_label"]))
print("[\n" + ",\n".join(lines) + "\n]")
PY
)"
    cat > "$TFVARS_OUT" <<EOF
# Generated by deploy.sh — do not commit. Token comes from \$TF_VAR_token.
region           = "${REGION}"
k8s_version      = "${K8S_VERSION}"
label            = "${LABEL}"
cpu_node_type    = "${CPU_NODE_TYPE}"
cpu_node_count   = ${CPU_NODE_COUNT}
multi_model      = true
gpu_pools        = ${GPU_POOLS_HCL}
domain           = "${DOMAIN}"
subdomain_prefix = "${SUBDOMAIN_PREFIX}"
cert_email       = "${CERT_EMAIL}"
allowed_cidr     = "${ALLOWED_CIDR}"
EOF
fi
ok "Wrote ${TFVARS_OUT}"

# Component composition, written into the helm overrides so the templates/scripts
# added in later phases can consume it. Always emitted; every value defaults to
# today's behavior, and templates gate on "differs from default", so the default
# render is unchanged.
COMPONENTS_YAML="$(cat <<EOF
editor: ${EDITOR}
inference: ${INFERENCE}
gpus_per_student: ${GPUS_PER_STUDENT}
cluster_access: ${CLUSTER_ACCESS}
object_storage: ${OBJECT_STORAGE}
agent_deploy: ${AGENT_DEPLOY}
EOF
)"

# ---- Write Helm overrides (merged over infra/helm/values.yaml) ----
if [[ $MULTI_MODEL -eq 0 ]]; then
    # Single-model: write model-specific vllm_extra_args from the sizing plan.
    VLLM_ARGS_YAML="$(python3 - <<PY
import json
p = json.loads('''$PLAN_JSON''')
for a in p.get("vllm_args", []):
    print('  - "%s"' % a)
PY
)"
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
${COMPONENTS_YAML}
hf_token: ""
vllm_extra_args:
${VLLM_ARGS_YAML}
EOF
else
    # Multi-model goes through the agentgateway, so it gets API-key auth: mint a key
    # (students send it as VLLM_API_KEY / `Authorization: Bearer`). Reuse a pre-set
    # key on re-runs so existing pods keep working.
    GATEWAY_API_KEY="${GATEWAY_API_KEY:-sk-workshop-$(openssl rand -hex 20)}"
    # Multi-model: emit models list with per-model extra_args.
    MODELS_YAML="$(python3 - <<PY
import json
p = json.loads('''$PLAN_JSON''')
lines = []
for m in p["models"]:
    lines.append('  - name: "%s"' % m["model"])
    lines.append('    slug: "%s"' % m["model_slug"])
    lines.append('    replicas: %d' % m["replicas"])
    lines.append('    tensor_parallel_size: %d' % m["tensor_parallel_size"])
    lines.append('    gpu_pool_label: "%s"' % m["gpu_pool_label"])
    args = m.get("vllm_args", [])
    if args:
        lines.append('    extra_args:')
        for a in args:
            lines.append('      - "%s"' % a)
print("\n".join(lines))
PY
)"
    cat > "$HELM_VALUES_OUT" <<EOF
# Generated by deploy.sh — do not commit.
namespace: ${NAMESPACE}
student_count: ${STUDENTS}
multi_model: true
models:
${MODELS_YAML}
max_model_len: ${MAX_MODEL_LEN}
gpu_memory_util: ${GPU_MEMORY_UTIL}
workspace_image: ${WORKSPACE_IMAGE}
vllm_host: http://agentgateway:8080/v1
content_repo: "${CONTENT_REPO}"
gateway_api_key: "${GATEWAY_API_KEY}"
${COMPONENTS_YAML}
hf_token: ""
EOF
fi
ok "Wrote ${HELM_VALUES_OUT}"

# ---- Provision (terraform + helm + vLLM + TLS) ----
echo ""
rule
printf '%b\n' "  ${BOLD}Provisioning${RESET}"
rule
env NAMESPACE="$NAMESPACE" DOMAIN="$DOMAIN" SUBDOMAIN_PREFIX="$SUBDOMAIN_PREFIX" \
    CERT_EMAIL="$CERT_EMAIL" HELM_VALUES="$HELM_VALUES_OUT" \
    STUDENT_COUNT="$STUDENTS" "${SCRIPTS}/provision.sh"

# ---- Base host (for student URLs) ----
BASE_HOST="$(cd "$TF_DIR" && terraform output -raw base_host)"

# ---- Generate per-student workspaces ----
echo ""
rule
printf '%b\n' "  ${BOLD}Generating ${STUDENTS} student workspaces${RESET}"
rule
GEN_PODS_ARGS=(-n "$STUDENTS" --host "$BASE_HOST"
    --namespace "$NAMESPACE" --image "$WORKSPACE_IMAGE"
    --workspace-type "$EDITOR" --content-repo "$CONTENT_REPO")
if [[ $MULTI_MODEL -eq 0 ]]; then
    GEN_PODS_ARGS+=(--model "$MODEL")
else
    GEN_PODS_ARGS+=(--model "$MODEL" --vllm-host "http://agentgateway:8080/v1"
        --model-names "$MODELS" --api-key "$GATEWAY_API_KEY")
fi
env NAMESPACE="$NAMESPACE" "${SCRIPTS}/generate-pods.sh" "${GEN_PODS_ARGS[@]}"

export KUBECONFIG="${INFRA}/kubeconfig.yaml"
kubectl apply -f "${GEN_DIR}/"

# ---- Done ----
CSV="${GEN_DIR}/access-cards.csv"
echo ""
rule
printf '%b\n' "  ${GREEN}${BOLD}Classroom ready${RESET}"
rule
INFER_EP="http://vllm:8000/v1"
[[ $MULTI_MODEL -eq 1 ]] && INFER_EP="http://agentgateway:8080/v1"
echo ""
printf "  ${DIM}%-14s${RESET} %s\n" "Base host:"    "$BASE_HOST"
printf "  ${DIM}%-14s${RESET} %s\n" "Model(s):"     "${MODELS//,/, }"
printf "  ${DIM}%-14s${RESET} %s\n" "Inference:"    "${INFER_EP}  (in-cluster only)"
if [[ -n "$GATEWAY_API_KEY" ]]; then
    printf "  ${DIM}%-14s${RESET} %s\n" "API key:"      "$GATEWAY_API_KEY"
    printf '%b\n' "  ${DIM}               injected into every workspace as \$VLLM_API_KEY (sent as Bearer);${RESET}"
    printf '%b\n' "  ${DIM}               not exposed publicly (ClusterIP + NetworkPolicy-gated)${RESET}"
else
    printf '%b\n' "  ${DIM}               reached from a student workspace via \$VLLM_HOST — no API key;${RESET}"
    printf '%b\n' "  ${DIM}               not exposed publicly (ClusterIP + NetworkPolicy-gated)${RESET}"
fi
printf "  ${DIM}%-14s${RESET} %s\n" "Access cards:" "$CSV"
if [[ -f "$CSV" ]]; then
    echo ""
    head -6 "$CSV" | sed 's/^/  /'
    [[ $(wc -l <"$CSV") -gt 6 ]] && printf '%b\n' "  ${DIM}($(($(wc -l <"$CSV")-1)) students total)${RESET}"
fi
echo ""
printf "  ${DIM}%-14s${RESET} %s\n" "Print cards:" "${SCRIPTS}/print-access-cards.sh"
printf "  ${DIM}%-14s${RESET} %s\n" "Tear down:"   "./deploy.sh teardown"

# TLS status — warn loudly if the cert secret never got created (a silent issue-cert
# failure otherwise leaves every URL on nginx's "not secure" self-signed fallback).
# Existence alone isn't enough in domain mode: a wrong-SAN or self-signed secret
# serves the same "not secure" page while passing a bare 'get secret', so check
# what the cert actually covers and who signed it.
_REISSUE_HINT="cd infra && LINODE_TOKEN=<token w/ Domains:R/W> DOMAIN=${DOMAIN} SUBDOMAIN_PREFIX=${SUBDOMAIN_PREFIX} NAMESPACE=${NAMESPACE} ./scripts/issue-cert.sh"
if ! kubectl -n "$NAMESPACE" get secret workshop-tls >/dev/null 2>&1; then
    echo ""
    warn "TLS NOT SECURED: 'workshop-tls' secret is missing — browsers will show \"not secure\"."
    printf '%b\n' "  ${DIM}nginx is serving its self-signed fallback. Issue the real cert (idempotent):${RESET}"
    if [[ -n "$DOMAIN" ]]; then
        printf '%b\n' "  ${DIM}  ${_REISSUE_HINT}${RESET}"
    else
        printf '%b\n' "  ${DIM}  cd infra && NAMESPACE=${NAMESPACE} ./scripts/issue-cert.sh${RESET}"
    fi
elif [[ -n "$DOMAIN" ]] && command -v openssl >/dev/null 2>&1; then
    # kubectl decodes base64 itself — portable across macOS/Linux base64 flags.
    _TLS_CRT="$(kubectl -n "$NAMESPACE" get secret workshop-tls \
        -o go-template='{{index .data "tls.crt" | base64decode}}' 2>/dev/null || true)"
    _PROBE_HOST="s01.${SUBDOMAIN_PREFIX}.${DOMAIN}"
    if [[ -n "$_TLS_CRT" ]]; then
        _CRT_SUBJECT="$(printf '%s' "$_TLS_CRT" | openssl x509 -noout -subject 2>/dev/null | sed 's/^subject= *//')"
        _CRT_ISSUER="$(printf '%s' "$_TLS_CRT" | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer= *//')"
        if ! printf '%s' "$_TLS_CRT" | openssl x509 -noout -checkhost "$_PROBE_HOST" 2>/dev/null | grep -q "does match"; then
            echo ""
            warn "TLS MISMATCH: workshop-tls exists but does not cover ${_PROBE_HOST} — browsers will show \"not secure\"."
            printf '%b\n' "  ${DIM}Re-issue with the right names (idempotent):${RESET}"
            printf '%b\n' "  ${DIM}  ${_REISSUE_HINT}${RESET}"
        elif [[ -n "$_CRT_SUBJECT" && "$_CRT_SUBJECT" == "$_CRT_ISSUER" ]]; then
            echo ""
            warn "TLS SELF-SIGNED: workshop-tls covers ${_PROBE_HOST} but is not CA-signed — browsers will show \"not secure\"."
            printf '%b\n' "  ${DIM}Issue a trusted Let's Encrypt cert (idempotent):${RESET}"
            printf '%b\n' "  ${DIM}  ${_REISSUE_HINT}${RESET}"
        fi
    fi
fi
echo ""
