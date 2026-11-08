#!/usr/bin/env bash
set -euo pipefail

# mirror-models.sh — seed a Linode Object Storage "model mirror" so per-student vLLM
# pods sync models from in-region object storage instead of huggingface.co (avoids HF
# rate-limiting at large scale). Run ONCE before a big deploy.
#
# Flow: create bucket -> mint a read_write key (upload) + a read_only key (pods) ->
# download the models locally (huggingface_hub) -> `aws s3 sync` them up -> write
# infra/manifests/generated/model-mirror.conf so `make deploy` auto-uses the mirror.
#
# Requires: aws CLI (bulk upload), python3 + huggingface_hub (download), curl, and the
# operator token ($TF_VAR_token / $LINODE_TOKEN). The bucket is created on an E3 endpoint
# and never in us-sea (policy, see obj-storage-lib.sh).
#
#   make mirror-models ARGS="--bucket acme-model-mirror --region us-ord"
#   make mirror-models ARGS="--bucket acme-model-mirror --models RedHatAI/Qwen3-4B-FP8-dynamic,Qwen/Qwen3-0.6B"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(dirname "$INFRA_DIR")"
# Run Python via the project .venv when present (repo convention; it holds the deps).
PY="python3"; [[ -x "${ROOT_DIR}/.venv/bin/python" ]] && PY="${ROOT_DIR}/.venv/bin/python"
GENERATED="${INFRA_DIR}/manifests/generated"
# Durable: lives OUTSIDE generated/ so `make teardown` (rm -rf generated/) can't wipe the
# mirror pointer/key while the mirror bucket itself survives. Auto-sourced by deploy.sh.
CONF="${INFRA_DIR}/model-mirror.conf"
# shellcheck source=obj-storage-lib.sh
source "${SCRIPT_DIR}/obj-storage-lib.sh"

# Linode's S3 rejects the checksums recent aws-cli v2 adds by default; only send when needed.
export AWS_REQUEST_CHECKSUM_CALCULATION="${AWS_REQUEST_CHECKSUM_CALCULATION:-when_required}"
export AWS_RESPONSE_CHECKSUM_VALIDATION="${AWS_RESPONSE_CHECKSUM_VALIDATION:-when_required}"

REGION="us-ord"
BUCKET=""
PREFIX="hf-cache"
MODELS="RedHatAI/Qwen3-4B-FP8-dynamic,RedHatAI/Qwen3-0.6B-FP8-dynamic,Qwen/Qwen3-0.6B"
SKIP_SEED=0   # --skip-seed: bucket already has the models; just refresh the read-only key + conf

while [[ $# -gt 0 ]]; do
    case "$1" in
        --region) REGION="$2"; shift 2 ;;
        --bucket) BUCKET="$2"; shift 2 ;;
        --prefix) PREFIX="$2"; shift 2 ;;
        --models) MODELS="$2"; shift 2 ;;
        --skip-seed) SKIP_SEED=1; shift ;;
        -h|--help)
            echo "usage: mirror-models.sh --bucket NAME [--region us-ord] [--prefix hf-cache] [--models a,b,c]"
            echo "  Seeds an Object Storage model mirror and writes model-mirror.conf for deploy.sh."
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

[[ -n "$BUCKET" ]] || { echo "ERROR: --bucket is required (globally-unique Object Storage bucket name)." >&2; exit 1; }

# S3 bucket names must be lowercase, DNS-safe, 3–63 chars. Normalize so an uppercase or
# punctuated name doesn't 400 (the usual cause). Print the final name we actually use.
SAFE_BUCKET="$(printf '%s' "$BUCKET" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed -E 's/-+/-/g; s/^-+//; s/-+$//')"
SAFE_BUCKET="${SAFE_BUCKET:0:63}"; SAFE_BUCKET="${SAFE_BUCKET%-}"
if [[ "$SAFE_BUCKET" != "$BUCKET" ]]; then
    echo "  note: normalized bucket name to '${SAFE_BUCKET}' (S3 names must be lowercase/DNS-safe)" >&2
    BUCKET="$SAFE_BUCKET"
fi
[[ "${#BUCKET}" -ge 3 ]] || { echo "ERROR: bucket name '${BUCKET}' is too short (min 3 chars after normalizing)." >&2; exit 1; }

# Policy: never a bucket in us-sea (E3 endpoints only). Checked before any network or tool
# check so the error is immediate and offline-testable.
if obj_region_denied "$REGION"; then
    echo "ERROR: region '${REGION}' is not allowed for Object Storage (policy: E3 endpoints only, never ${OBJ_DENY_REGIONS}). Use --region us-ord; GPU nodes may still run in ${REGION}." >&2
    exit 1
fi

if [[ -z "${LINODE_CLI_TOKEN:-}" ]]; then export LINODE_CLI_TOKEN="${TF_VAR_token:-${LINODE_TOKEN:-}}"; fi
[[ -n "${LINODE_CLI_TOKEN:-}" ]] || { echo "ERROR: set TF_VAR_token or LINODE_TOKEN." >&2; exit 1; }
command -v "$PY" >/dev/null 2>&1 || { echo "ERROR: python not found (${PY})." >&2; exit 1; }
# aws CLI + huggingface_hub are only needed to SEED (download+upload), not to refresh the conf.
if [[ "$SKIP_SEED" -eq 0 ]]; then
    command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found (needed for the bulk upload). Install awscli." >&2; exit 1; }
    if ! "$PY" -c 'import huggingface_hub' >/dev/null 2>&1; then
        echo "  huggingface_hub not found in ${PY} — installing it ..." >&2
        "$PY" -m pip install -q huggingface_hub >&2 \
            || { echo "ERROR: could not install huggingface_hub. Run: ${PY} -m pip install huggingface_hub" >&2; exit 1; }
    fi
fi

# Resolve the E3 endpoint for the region. The hostname comes from the API (us-ord-10...),
# never from a guessed "<region>-1" cluster id.
RESOLVED="$(obj_resolve_endpoint "$REGION")" || exit 1
read -r OBJ_REGION OBJ_S3_ENDPOINT <<<"$RESOLVED"
OBJ_S3_ENDPOINT="${OBJ_S3_ENDPOINT:-}"

echo "=== Model mirror: bucket '$BUCKET' in $OBJ_REGION (${OBJ_ENDPOINT_TYPE} endpoint) ==="

# Create the E3 bucket. Idempotent: a bucket you already own 2xxs. The response carries
# the real S3 endpoint for this region.
EP="$(obj_create_bucket "$OBJ_REGION" "$BUCKET")" || {
    echo "ERROR: bucket create failed (bucket names are GLOBAL — if it's taken, pick another)." >&2
    exit 1
}
if [[ -n "$EP" ]]; then OBJ_S3_ENDPOINT="$EP"; fi
if [[ -z "$OBJ_S3_ENDPOINT" ]]; then OBJ_S3_ENDPOINT="$(obj_bucket_field "$BUCKET" s3_endpoint)"; fi
[[ -n "$OBJ_S3_ENDPOINT" ]] || { echo "ERROR: could not determine the ${OBJ_ENDPOINT_TYPE} S3 endpoint for ${BUCKET} in ${OBJ_REGION}." >&2; exit 1; }
ENDPOINT="https://${OBJ_S3_ENDPOINT}"
echo "  bucket ready at ${ENDPOINT}"

# Mint a read_write key (upload) and a read_only key (pods), both scoped to this bucket.
mint_key() {  # $1=label $2=permissions -> "ACCESS_KEY SECRET_KEY"
    local kid ak sk
    # Drop any prior key with this exact label so retries don't accumulate orphans.
    for kid in $(obj_py "$(obj_list_keys)" '
import json, sys
try:
    parsed = json.load(sys.stdin)
    data = parsed.get("data", []) if isinstance(parsed, dict) else parsed
except Exception:
    data = []
for k in data:
    if str(k.get("label", "")) == sys.argv[1]:
        print(k.get("id", ""))
' "$1"); do
        if [[ -n "$kid" ]]; then obj_delete_key "$kid"; fi
    done
    read -r _ ak sk <<<"$(obj_create_key "$1" "$OBJ_REGION" "$BUCKET" "$2")"
    printf '%s %s\n' "${ak:-}" "${sk:-}"
}
# Pods only ever need the read-only key.
read -r AK_RO SK_RO < <(mint_key "${BUCKET}-ro" read_only)
[[ -n "$AK_RO" && -n "$SK_RO" ]] || { echo "ERROR: could not mint read_only key." >&2; exit 1; }

if [[ "$SKIP_SEED" -eq 0 ]]; then
    # Mint a read_write key, download the models locally (HF cache layout), sync the tree up.
    read -r AK_RW SK_RW < <(mint_key "${BUCKET}-rw" read_write)
    [[ -n "$AK_RW" && -n "$SK_RW" ]] || { echo "ERROR: could not mint read_write key." >&2; exit 1; }
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    echo "  downloading models: $MODELS"
    MODELS="$MODELS" CACHE="$TMP" "$PY" - <<'PY'
import os
from huggingface_hub import snapshot_download
for m in os.environ["MODELS"].split(","):
    m = m.strip()
    if m:
        print("  >>", m); snapshot_download(m, cache_dir=os.environ["CACHE"])
PY
    echo "  uploading to s3://${BUCKET}/${PREFIX}/ ..."
    AWS_ACCESS_KEY_ID="$AK_RW" AWS_SECRET_ACCESS_KEY="$SK_RW" AWS_DEFAULT_REGION="$OBJ_REGION" \
        aws s3 sync "$TMP" "s3://${BUCKET}/${PREFIX}" --endpoint-url "$ENDPOINT" --only-show-errors
    echo "  upload complete"
else
    echo "  --skip-seed: bucket assumed already seeded; refreshed read-only key + conf only"
fi

# Write the auto-pickup conf (read_only key for pods). Gitignored; holds a secret → 0600.
mkdir -p "$(dirname "$CONF")"
( umask 077; cat > "$CONF" <<EOF
# Generated by mirror-models.sh — do not commit. Auto-sourced by deploy.sh.
MODEL_MIRROR_BUCKET="${BUCKET}"
MODEL_MIRROR_ENDPOINT="${ENDPOINT}"
MODEL_MIRROR_REGION="${OBJ_REGION}"
MODEL_MIRROR_ENDPOINT_TYPE="${OBJ_ENDPOINT_TYPE}"
MODEL_MIRROR_PREFIX="${PREFIX}"
MODEL_MIRROR_ACCESS_KEY="${AK_RO}"
MODEL_MIRROR_SECRET_KEY="${SK_RO}"
EOF
)

echo ""
echo "=== Mirror ready ==="
echo "Wrote ${CONF} (read-only key; gitignored)."
echo "'make deploy' now uses the mirror automatically; pods sync from s3://${BUCKET}/${PREFIX}."
