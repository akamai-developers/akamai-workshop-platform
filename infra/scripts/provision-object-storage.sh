#!/usr/bin/env bash
set -euo pipefail

# provision-object-storage.sh — per-student Object Storage buckets + bucket-scoped
# limited keys (object_storage=managed). Sibling to generate-pods.sh.
#
# For each student it creates ONE bucket and mints a LIMITED access key locked to
# that single bucket (read_write). That scoping IS the isolation: a student's key
# physically cannot read another student's bucket. Students NEVER receive the
# operator master token — only their own bucket-scoped key, injected as a per-student
# Secret → env (AWS_ACCESS_KEY_ID/SECRET, SESSION_BUCKET/ENDPOINT_URL/REGION).
#
# Idempotent like generate-pods.sh: a sidecar `object-storage.csv` (gitignored, in
# generated/) records the provisioned bucket + key per student. Re-running PRESERVES
# existing rows (secret_key is only returned at create time, so it must be kept) and
# only provisions students that don't yet have a row.
#
# Teardown (--teardown): empties + deletes every bucket and revokes every key whose
# label/name matches the run prefix — leak-proof and idempotent. Wired into
# teardown.sh and the e2e-smoke EXIT trap.
#
# GOTCHA (verified live): bucket + key creation take the REGION id (e.g. us-iad — the
# `region` column of `object-storage clusters-list`), NOT the cluster id (us-iad-1).
# Empty --regions → 500; wrong value → 400. This script resolves the region id from
# clusters-list before creating anything.
#
# Usage:
#   ./provision-object-storage.sh -n 80 --region us-ord --prefix acme-workshop \
#       --namespace workshop [--cluster-access scoped]
#   ./provision-object-storage.sh --teardown --prefix acme-workshop --region us-ord
#
# NOTE: real bucket/key provisioning is NOT exercised in the paid e2e smoke; this
# script is verified OFFLINE against tests/fakes/linode-cli.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="${OUTPUT_DIR:-${INFRA_DIR}/manifests/generated}"

# Overridable so bats can point at the fake; PATH resolution finds the fake otherwise.
LINODECLI="${LINODECLI:-linode-cli}"

CSV="${OUTPUT_DIR}/object-storage.csv"
SECRETS="${OUTPUT_DIR}/workspace-object-storage.yaml"
CSV_TMP="${CSV}.tmp"
SECRETS_TMP="${SECRETS}.tmp"

COUNT=80
REGION="${REGION:-}"
PREFIX="${PREFIX:-}"
NAMESPACE="${NAMESPACE:-workshop}"
CLUSTER_ACCESS="${CLUSTER_ACCESS:-none}"
TEARDOWN=0

while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--count) COUNT="$2"; shift 2 ;;
        --region) REGION="$2"; shift 2 ;;
        --prefix) PREFIX="$2"; shift 2 ;;
        --namespace) NAMESPACE="$2"; shift 2 ;;
        --cluster-access) CLUSTER_ACCESS="$2"; shift 2 ;;
        --teardown) TEARDOWN=1; shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 [-n COUNT] --region REGION --prefix PREFIX [options]
  -n, --count       Number of students (default: 80)
  --region          LKE/Object-Storage region (e.g. us-ord); resolved to the region id
  --prefix          Bucket/key name prefix (use the unique run label; buckets are GLOBAL)
  --namespace       Base namespace for emitted Secrets (default: workshop)
  --cluster-access  none (default) | scoped — scoped puts each Secret in <namespace>-sNN
  --teardown        Revoke every key + empty/delete every bucket matching --prefix
EOF
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# Forward the operator token to linode-cli (it also reads its own config file).
if [[ -z "${LINODE_CLI_TOKEN:-}" ]]; then
    export LINODE_CLI_TOKEN="${TF_VAR_token:-${LINODE_TOKEN:-}}"
fi

if [[ -z "${PREFIX}" ]]; then
    echo "ERROR: --prefix is required (buckets are GLOBALLY unique — use the run label)." >&2
    exit 1
fi

# Bucket names: lowercase, DNS-safe, 3–63 chars. Sanitize + truncate the prefix so
# "<prefix>-sNN" always fits.
SAFE_PREFIX="$(printf '%s' "${PREFIX}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed -E 's/-+/-/g; s/^-+//; s/-+$//')"
SAFE_PREFIX="${SAFE_PREFIX:0:50}"
SAFE_PREFIX="${SAFE_PREFIX%-}"
if [[ -z "${SAFE_PREFIX}" ]]; then
    echo "ERROR: --prefix '${PREFIX}' sanitized to empty; pass an alphanumeric prefix." >&2
    exit 1
fi

bucket_name() { printf '%s-s%s' "${SAFE_PREFIX}" "$1"; }
key_label()   { printf '%s-s%s-key' "${SAFE_PREFIX}" "$1"; }

# Student namespace for the emitted Secret (mirrors generate-pods.sh / generate-kubeconfig.sh).
student_ns() {
    if [[ "${CLUSTER_ACCESS}" == "scoped" ]]; then
        printf '%s-s%s' "${NAMESPACE}" "$1"
    else
        printf '%s' "${NAMESPACE}"
    fi
}

mkdir -p "${OUTPUT_DIR}"

# ---------------------------------------------------------------------------
# Resolve the Object Storage region id (us-ord) and cluster id (us-ord-1) from
# clusters-list. Creation params take the region id; the S3 endpoint uses the
# cluster id. Passing the cluster id to --region is the documented 400.
# ---------------------------------------------------------------------------
OBJ_REGION=""
OBJ_CLUSTER_ID=""
resolve_region() {
    local want="$1" json
    if [[ -z "${want}" ]]; then
        echo "ERROR: --region is required to resolve the Object Storage region id." >&2
        exit 1
    fi
    json="$("${LINODECLI}" object-storage clusters-list --json 2>/dev/null || true)"
    local resolved
    resolved="$(python3 - "${json}" "${want}" <<'PY'
import json, sys
want = sys.argv[2]
try:
    data = json.loads(sys.argv[1])
except Exception:
    data = []
# Match on the region column (us-ord) first, then tolerate a cluster id (us-ord-1).
for c in data:
    if c.get("region") == want:
        print(c.get("region", ""), c.get("id", "")); break
else:
    for c in data:
        if c.get("id") == want or str(c.get("id", "")).startswith(want):
            print(c.get("region", ""), c.get("id", "")); break
PY
)"
    OBJ_REGION="$(awk '{print $1}' <<<"${resolved}")"
    OBJ_CLUSTER_ID="$(awk '{print $2}' <<<"${resolved}")"
    if [[ -z "${OBJ_REGION}" ]]; then
        echo "ERROR: region '${want}' not found in object-storage clusters-list (Object Storage enabled there?)." >&2
        exit 1
    fi
    : "${OBJ_CLUSTER_ID:=${OBJ_REGION}}"
}

endpoint_url() { printf 'https://%s.linodeobjects.com' "${OBJ_CLUSTER_ID}"; }

# ---------------------------------------------------------------------------
# Teardown: revoke keys + empty/delete buckets matching the prefix. Idempotent.
# ---------------------------------------------------------------------------
if [[ ${TEARDOWN} -eq 1 ]]; then
    resolve_region "${REGION}"

    # Revoke every limited key whose label matches "<prefix>-sNN-key".
    KEYS_JSON="$("${LINODECLI}" object-storage keys-list --json 2>/dev/null || true)"
    REVOKE_IDS="$(python3 - "${KEYS_JSON}" "${SAFE_PREFIX}" <<'PY'
import json, re, sys
prefix = sys.argv[2]
try:
    data = json.loads(sys.argv[1])
except Exception:
    data = []
pat = re.compile(r'^' + re.escape(prefix) + r'-s\d{2}-key$')
for k in data:
    if pat.match(str(k.get("label", ""))):
        print(k.get("id", ""))
PY
)"
    for kid in ${REVOKE_IDS}; do
        [[ -n "${kid}" ]] || continue
        echo "  revoking object-storage key ${kid}"
        "${LINODECLI}" object-storage keys-delete "${kid}" >/dev/null 2>&1 || true
    done

    # Empty + delete every bucket matching "<prefix>-sNN". Use the per-student key
    # (from the CSV, if present) to empty objects; delete the bucket with the token.
    BUCKETS_JSON="$("${LINODECLI}" object-storage buckets-list --json 2>/dev/null || true)"
    DEL_BUCKETS="$(python3 - "${BUCKETS_JSON}" "${SAFE_PREFIX}" <<'PY'
import json, re, sys
prefix = sys.argv[2]
try:
    data = json.loads(sys.argv[1])
except Exception:
    data = []
pat = re.compile(r'^' + re.escape(prefix) + r'-s\d{2}$')
for b in data:
    name = b.get("label") or b.get("name") or ""
    if pat.match(str(name)):
        print(name)
PY
)"
    for bucket in ${DEL_BUCKETS}; do
        [[ -n "${bucket}" ]] || continue
        echo "  emptying + deleting bucket ${bucket}"
        # Empty objects with the bucket's own key if we still have it (read_write
        # covers object deletion). Best-effort; the API delete below is the backstop.
        if [[ -f "${CSV}" ]]; then
            CREDS="$(awk -F, -v b="${bucket}" '$2==b {print $4" "$5}' "${CSV}" | head -1)"
            AK="$(awk '{print $1}' <<<"${CREDS}")"; SK="$(awk '{print $2}' <<<"${CREDS}")"
            if [[ -n "${AK}" && -n "${SK}" ]]; then
                LINODE_CLI_OBJ_ACCESS_KEY="${AK}" LINODE_CLI_OBJ_SECRET_KEY="${SK}" \
                    "${LINODECLI}" obj --cluster "${OBJ_REGION}" rb --recursive "s3://${bucket}" >/dev/null 2>&1 || true
            fi
        fi
        # Backstop: delete the (now-empty) bucket with the operator token.
        "${LINODECLI}" object-storage buckets-delete "${OBJ_REGION}" "${bucket}" >/dev/null 2>&1 || true
    done

    # Drop the local state once buckets/keys are gone.
    rm -f "${CSV}" "${SECRETS}"
    echo "Object Storage teardown complete (prefix '${SAFE_PREFIX}')."
    exit 0
fi

# ---------------------------------------------------------------------------
# Provision: per-student bucket + bucket-scoped key (idempotent via the CSV).
# ---------------------------------------------------------------------------
resolve_region "${REGION}"
ENDPOINT="$(endpoint_url)"

cleanup_tmp() { rm -f "${CSV_TMP}" "${SECRETS_TMP}"; }
trap cleanup_tmp ERR

# Read existing rows so re-runs preserve buckets + keys (secret_key isn't recoverable).
# Plain indexed arrays (keyed by student number) — bash 3.2 has no associative arrays.
EXIST_BUCKET=(); EXIST_KEYID=(); EXIST_AK=(); EXIST_SK=()
if [[ -f "${CSV}" ]]; then
    while IFS=, read -r num bucket keyid ak sk || [[ -n "${num}" ]]; do
        [[ "${num}" == "student_number" ]] && continue
        [[ "${num}" =~ ^s([0-9]{2})$ ]] || continue
        n=$((10#${BASH_REMATCH[1]}))
        EXIST_BUCKET[n]="${bucket}"; EXIST_KEYID[n]="${keyid}"
        EXIST_AK[n]="${ak}"; EXIST_SK[n]="${sk%$'\r'}"
    done < "${CSV}"
fi

echo "student_number,bucket,key_id,access_key,secret_key" > "${CSV_TMP}"
: > "${SECRETS_TMP}"

NEW=0
for i in $(seq 1 "${COUNT}"); do
    PADDED=$(printf "%02d" "$i")
    BUCKET="$(bucket_name "${PADDED}")"
    NS_I="$(student_ns "${PADDED}")"

    if [[ -n "${EXIST_AK[$i]:-}" ]]; then
        # Preserve: bucket + key already provisioned for this student.
        BUCKET="${EXIST_BUCKET[$i]}"
        KEY_ID="${EXIST_KEYID[$i]}"; ACCESS_KEY="${EXIST_AK[$i]}"; SECRET_KEY="${EXIST_SK[$i]}"
    else
        NEW=$((NEW+1))
        # Create the bucket (region id, not cluster id). Tolerate "already exists".
        "${LINODECLI}" object-storage buckets-create --region "${OBJ_REGION}" --label "${BUCKET}" --json >/dev/null 2>&1 || true
        # Mint a LIMITED key locked to this single bucket (read_write).
        KEY_JSON="$("${LINODECLI}" object-storage keys-create \
            --label "$(key_label "${PADDED}")" \
            --regions "${OBJ_REGION}" \
            --bucket_access.region "${OBJ_REGION}" \
            --bucket_access.bucket_name "${BUCKET}" \
            --bucket_access.permissions read_write \
            --json 2>/dev/null || true)"
        read -r KEY_ID ACCESS_KEY SECRET_KEY < <(python3 - "${KEY_JSON}" <<'PY'
import json, sys
try:
    data = json.loads(sys.argv[1])
    k = data[0] if isinstance(data, list) else data
    print(k.get("id", ""), k.get("access_key", ""), k.get("secret_key", ""))
except Exception:
    print("", "", "")
PY
)
        if [[ -z "${ACCESS_KEY}" || -z "${SECRET_KEY}" ]]; then
            echo "ERROR: keys-create returned no key for student s${PADDED} (bucket ${BUCKET})." >&2
            exit 1
        fi
    fi

    echo "s${PADDED},${BUCKET},${KEY_ID},${ACCESS_KEY},${SECRET_KEY}" >> "${CSV_TMP}"

    cat >> "${SECRETS_TMP}" << EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: ws-${PADDED}-object-storage
  namespace: ${NS_I}
  labels:
    app: akamai-workshop-platform
    awp-student-number: "${i}"
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: "${ACCESS_KEY}"
  AWS_SECRET_ACCESS_KEY: "${SECRET_KEY}"
  SESSION_BUCKET: "${BUCKET}"
  SESSION_ENDPOINT_URL: "${ENDPOINT}"
  SESSION_REGION: "${OBJ_REGION}"
EOF
done

mv "${CSV_TMP}" "${CSV}"
mv "${SECRETS_TMP}" "${SECRETS}"

echo ""
echo "=== Object Storage provisioned (region ${OBJ_REGION}, endpoint ${ENDPOINT}) ==="
if [[ ${NEW} -gt 0 ]]; then
    echo "Provisioned ${NEW} new bucket(s)+key(s); preserved $((COUNT-NEW)) existing."
else
    echo "Preserved ${COUNT} existing bucket(s)+key(s); re-emitted Secrets only."
fi
echo "Files:"
echo "  ${SECRETS}   (per-student Secret → env)"
echo "  ${CSV}       (bucket+key state — gitignored, NEVER commit)"
echo "Apply with: kubectl apply -f ${SECRETS}"
