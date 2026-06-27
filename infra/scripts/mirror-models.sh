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
# Requires: aws CLI (bulk upload), python3 + huggingface_hub (download), linode-cli,
# and the operator token ($TF_VAR_token / $LINODE_TOKEN).
#
#   make mirror-models ARGS="--bucket acme-model-mirror --region us-sea"
#   make mirror-models ARGS="--bucket acme-model-mirror --models RedHatAI/Qwen3-4B-FP8-dynamic,Qwen/Qwen3-0.6B"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(dirname "$INFRA_DIR")"
# Run Python via the project .venv when present (repo convention; it holds the deps).
PY="python3"; [[ -x "${ROOT_DIR}/.venv/bin/python" ]] && PY="${ROOT_DIR}/.venv/bin/python"
GENERATED="${INFRA_DIR}/manifests/generated"
CONF="${GENERATED}/model-mirror.conf"
LINODECLI="${LINODECLI:-linode-cli}"
OBJ_API="${OBJ_API:-https://api.linode.com/v4/object-storage}"

# Linode's S3 rejects the checksums recent aws-cli v2 adds by default; only send when needed.
export AWS_REQUEST_CHECKSUM_CALCULATION="${AWS_REQUEST_CHECKSUM_CALCULATION:-when_required}"
export AWS_RESPONSE_CHECKSUM_VALIDATION="${AWS_RESPONSE_CHECKSUM_VALIDATION:-when_required}"

REGION="us-sea"
BUCKET=""
PREFIX="hf-cache"
MODELS="RedHatAI/Qwen3-4B-FP8-dynamic,RedHatAI/Qwen3-0.6B-FP8-dynamic,Qwen/Qwen3-0.6B"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --region) REGION="$2"; shift 2 ;;
        --bucket) BUCKET="$2"; shift 2 ;;
        --prefix) PREFIX="$2"; shift 2 ;;
        --models) MODELS="$2"; shift 2 ;;
        -h|--help)
            echo "usage: mirror-models.sh --bucket NAME [--region us-sea] [--prefix hf-cache] [--models a,b,c]"
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

if [[ -z "${LINODE_CLI_TOKEN:-}" ]]; then export LINODE_CLI_TOKEN="${TF_VAR_token:-${LINODE_TOKEN:-}}"; fi
[[ -n "${LINODE_CLI_TOKEN:-}" ]] || { echo "ERROR: set TF_VAR_token or LINODE_TOKEN." >&2; exit 1; }
command -v aws     >/dev/null 2>&1 || { echo "ERROR: aws CLI not found (needed for the bulk upload). Install awscli." >&2; exit 1; }
command -v "$PY" >/dev/null 2>&1 || { echo "ERROR: python not found (${PY})." >&2; exit 1; }
# Ensure huggingface_hub (the download dep); install it into the .venv if missing.
if ! "$PY" -c 'import huggingface_hub' >/dev/null 2>&1; then
    echo "  huggingface_hub not found in ${PY} — installing it ..." >&2
    "$PY" -m pip install -q huggingface_hub >&2 \
        || { echo "ERROR: could not install huggingface_hub. Run: ${PY} -m pip install huggingface_hub" >&2; exit 1; }
fi

# Resolve the OS region id (us-sea) + cluster id (us-sea-1) -> endpoint (same as
# provision-object-storage.sh: creation takes the region id; the endpoint uses the cluster id).
JSON="$("${LINODECLI}" object-storage clusters-list --json 2>/dev/null || true)"
read -r OBJ_REGION OBJ_CLUSTER_ID < <("$PY" - "$JSON" "$REGION" <<'PY'
import json, sys
want = sys.argv[2]
try: data = json.loads(sys.argv[1])
except Exception: data = []
for c in data:
    if c.get("region") == want:
        print(c.get("region",""), c.get("id","")); break
else:
    for c in data:
        if c.get("id") == want or str(c.get("id","")).startswith(want):
            print(c.get("region",""), c.get("id","")); break
PY
)
[[ -n "$OBJ_REGION" ]] || { echo "ERROR: region '$REGION' not in object-storage clusters-list (Object Storage enabled there?)." >&2; exit 1; }
: "${OBJ_CLUSTER_ID:=$OBJ_REGION}"
ENDPOINT="https://${OBJ_CLUSTER_ID}.linodeobjects.com"

echo "=== Model mirror: bucket '$BUCKET' in $OBJ_REGION ($ENDPOINT) ==="

# Create the bucket (region id, not cluster id). Idempotent: a bucket you already own 2xxs.
resp="$(curl -s -w $'\n%{http_code}' -X POST "${OBJ_API}/buckets" \
    -H "Authorization: Bearer ${LINODE_CLI_TOKEN}" -H "Content-Type: application/json" \
    -d "{\"label\":\"${BUCKET}\",\"region\":\"${OBJ_REGION}\"}")"
code="$(tail -n1 <<<"$resp")"; body="$(sed '$d' <<<"$resp")"
case "$code" in
    2*) echo "  bucket ready" ;;
    *)  echo "ERROR: bucket create returned HTTP ${code}." >&2
        echo "  API said: ${body}" >&2
        echo "  (bucket names are GLOBAL — if it's taken, pick another; 400 usually = bad name/region)" >&2
        exit 1 ;;
esac

# Mint a read_write key (upload) and a read_only key (pods), both scoped to this bucket.
mint_key() {  # $1=label $2=permissions -> "ACCESS_KEY SECRET_KEY"
    local j existing kid
    # Drop any prior key with this exact label so retries don't accumulate orphans.
    existing="$("${LINODECLI}" object-storage keys-list --json 2>/dev/null || true)"
    for kid in $("$PY" - "$existing" "$1" <<'PY'
import json, sys
try: data = json.loads(sys.argv[1])
except Exception: data = []
for k in data:
    if str(k.get("label", "")) == sys.argv[2]:
        print(k.get("id", ""))
PY
); do
        [[ -n "$kid" ]] && "${LINODECLI}" object-storage keys-delete "$kid" >/dev/null 2>&1 || true
    done
    j="$("${LINODECLI}" object-storage keys-create --label "$1" --regions "$OBJ_REGION" \
        --bucket_access.region "$OBJ_REGION" --bucket_access.bucket_name "$BUCKET" \
        --bucket_access.permissions "$2" --json 2>/dev/null || true)"
    "$PY" - "$j" <<'PY'
import json, sys
try:
    d = json.loads(sys.argv[1]); k = d[0] if isinstance(d, list) else d
    print(k.get("access_key",""), k.get("secret_key",""))
except Exception:
    print("", "")
PY
}
read -r AK_RW SK_RW < <(mint_key "${BUCKET}-rw" read_write)
read -r AK_RO SK_RO < <(mint_key "${BUCKET}-ro" read_only)
[[ -n "$AK_RW" && -n "$SK_RW" ]] || { echo "ERROR: could not mint read_write key." >&2; exit 1; }
[[ -n "$AK_RO" && -n "$SK_RO" ]] || { echo "ERROR: could not mint read_only key." >&2; exit 1; }

# Download the models locally into a temp HF cache, then sync that tree to the bucket.
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

# Write the auto-pickup conf (read_only key for pods). Gitignored; holds a secret → 0600.
mkdir -p "$GENERATED"
( umask 077; cat > "$CONF" <<EOF
# Generated by mirror-models.sh — do not commit. Auto-sourced by deploy.sh.
MODEL_MIRROR_BUCKET="${BUCKET}"
MODEL_MIRROR_ENDPOINT="${ENDPOINT}"
MODEL_MIRROR_REGION="${OBJ_REGION}"
MODEL_MIRROR_PREFIX="${PREFIX}"
MODEL_MIRROR_ACCESS_KEY="${AK_RO}"
MODEL_MIRROR_SECRET_KEY="${SK_RO}"
EOF
)

echo ""
echo "=== Mirror ready ==="
echo "Wrote ${CONF} (read-only key; gitignored)."
echo "'make deploy' now uses the mirror automatically; pods sync from s3://${BUCKET}/${PREFIX}."
