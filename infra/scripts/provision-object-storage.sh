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
# Endpoint policy (obj-storage-lib.sh): E3 endpoints only, never us-sea. Buckets are
# created with endpoint_type=E3 and the S3 endpoint is read back from the API
# (e.g. us-ord-10.linodeobjects.com), never guessed from a "<region>-1" hostname.
#
# Idempotent like generate-pods.sh: a sidecar `object-storage.csv` (gitignored, in
# generated/) records the provisioned bucket + key per student. Re-running PRESERVES
# existing rows (secret_key is only returned at create time, so it must be kept) and
# only provisions students that don't yet have a row.
#
# Teardown (--teardown): empties + deletes every bucket and revokes every key whose
# label/name matches the run prefix, in whatever region they live. Leak-proof and
# idempotent; wired into teardown.sh and the e2e-smoke EXIT trap.
#
# Everything goes through the Linode REST API (curl + python3 stdlib): no linode-cli,
# no boto3. Verified OFFLINE against tests/fakes/curl (OBJ_API, S3_EMPTY overridable).
#
# Usage:
#   ./provision-object-storage.sh -n 80 --region us-ord --prefix acme-workshop \
#       --namespace workshop [--cluster-access scoped]
#   ./provision-object-storage.sh --teardown --prefix acme-workshop

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="${OUTPUT_DIR:-${INFRA_DIR}/manifests/generated}"

# shellcheck source=obj-storage-lib.sh
source "${SCRIPT_DIR}/obj-storage-lib.sh"

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
  --region          Object Storage region for the buckets (E3 only, e.g. us-ord; never us-sea)
  --prefix          Bucket/key name prefix (use the unique run label; buckets are GLOBAL)
  --namespace       Base namespace for emitted Secrets (default: workshop)
  --cluster-access  none (default) | scoped — scoped puts each Secret in <namespace>-sNN
  --teardown        Revoke every key + empty/delete every bucket matching --prefix (any region)
EOF
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# Forward the operator token (the lib reads LINODE_CLI_TOKEN first, then TF_VAR_token / LINODE_TOKEN).
if [[ -z "${LINODE_CLI_TOKEN:-}" ]]; then
    export LINODE_CLI_TOKEN="${TF_VAR_token:-${LINODE_TOKEN:-}}"
fi

# Bucket emptier used at teardown (the REST API refuses to delete a non-empty bucket).
# s3.py is a stdlib-only SigV4 S3 client. Overridable so bats can stub the network call.
S3_EMPTY="${S3_EMPTY:-python3 ${SCRIPT_DIR}/s3.py empty}"

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
# Teardown: empty + delete buckets, THEN revoke keys. Emptying a bucket needs its own
# key, so revocation MUST come last (revoking first leaves non-empty, undeletable
# buckets). Matches the prefix across every region; idempotent. --region is ignored
# here: each bucket's own region and endpoint come from the API listing.
# ---------------------------------------------------------------------------
if [[ ${TEARDOWN} -eq 1 ]]; then
    # Identify (do NOT yet revoke) keys whose label matches "<prefix>-sNN-key".
    REVOKE_IDS="$(obj_py "$(obj_list_keys)" '
import json, re, sys
prefix = sys.argv[1]
try:
    parsed = json.load(sys.stdin)
    data = parsed.get("data", []) if isinstance(parsed, dict) else parsed
except Exception:
    data = []
pat = re.compile(r"^" + re.escape(prefix) + r"-s\d{2,}-key$")
for k in data:
    if pat.match(str(k.get("label", ""))):
        print(k.get("id", ""))
' "${SAFE_PREFIX}")"

    # Every bucket matching "<prefix>-sNN", with its region + S3 endpoint from the API.
    DEL_BUCKETS="$(obj_py "$(obj_list_buckets)" '
import json, re, sys
prefix = sys.argv[1]
try:
    parsed = json.load(sys.stdin)
    data = parsed.get("data", []) if isinstance(parsed, dict) else parsed
except Exception:
    data = []
pat = re.compile(r"^" + re.escape(prefix) + r"-s\d{2,}$")
for b in data:
    name = b.get("label") or b.get("name") or ""
    if pat.match(str(name)):
        print(name, b.get("region") or "", b.get("s3_endpoint") or "")
' "${SAFE_PREFIX}")"
    LEAKED=""
    while read -r bucket bregion bendpoint; do
        [[ -n "${bucket}" ]] || continue
        echo "  emptying + deleting bucket ${bucket} (${bregion:-?})"
        # Empty objects with the bucket's OWN read_write key if we still have it (stdlib
        # SigV4, no boto3). E3 endpoints can reject a key for a few seconds after it is
        # minted (eventual consistency), so empty + delete + verify runs in a retry loop;
        # a 404 on the bucket is the only proof it is gone.
        AK=""; SK=""
        if [[ -f "${CSV}" ]]; then
            CREDS="$(awk -F, -v b="${bucket}" '$2==b {print $4" "$5}' "${CSV}" | head -1)"
            AK="$(awk '{print $1}' <<<"${CREDS}")"; SK="$(awk '{print $2}' <<<"${CREDS}")"
        fi
        GONE=0
        for _attempt in 1 2 3 4 5; do
            if [[ -n "${AK}" && -n "${SK}" && -n "${bendpoint}" && -n "${bregion}" ]]; then
                ${S3_EMPTY} --endpoint "https://${bendpoint}" --region "${bregion}" \
                    --bucket "${bucket}" --access-key "${AK}" --secret-key "${SK}" >/dev/null 2>&1 || true
            fi
            if [[ -n "${bregion}" ]]; then
                obj_delete_bucket "${bregion}" "${bucket}"
                if [[ "$(obj_code "$(obj_api GET "/buckets/${bregion}/${bucket}")")" == "404" ]]; then
                    GONE=1; break
                fi
            fi
            sleep $((_attempt * 3))
        done
        if [[ ${GONE} -eq 0 ]]; then
            echo "  WARN: bucket ${bucket} is still present (non-empty, or the endpoint is not yet consistent)." >&2
            LEAKED="${LEAKED} ${bucket}"
        fi
    done <<<"${DEL_BUCKETS}"

    if [[ -n "${LEAKED// /}" ]]; then
        # Keep the keys and the local CSV: a re-run needs them to empty what is left.
        echo "WARN: Object Storage teardown INCOMPLETE for prefix '${SAFE_PREFIX}':${LEAKED}" >&2
        echo "      Re-run: $0 --teardown --prefix '${PREFIX}'   (keys + object-storage.csv kept for the retry)" >&2
        exit 1
    fi

    # Now that the buckets are empty + deleted, revoke the per-student keys.
    for kid in ${REVOKE_IDS}; do
        [[ -n "${kid}" ]] || continue
        echo "  revoking object-storage key ${kid}"
        obj_delete_key "${kid}"
    done

    # Drop the local state once buckets/keys are gone.
    rm -f "${CSV}" "${SECRETS}"
    echo "Object Storage teardown complete (prefix '${SAFE_PREFIX}')."
    exit 0
fi

# ---------------------------------------------------------------------------
# Provision: per-student bucket + bucket-scoped key (idempotent via the CSV).
# ---------------------------------------------------------------------------
if [[ -z "${REGION}" ]]; then
    echo "ERROR: --region is required (an E3 Object Storage region, e.g. us-ord)." >&2
    exit 1
fi
RESOLVED="$(obj_resolve_endpoint "${REGION}")" || exit 1
read -r OBJ_REGION OBJ_S3_ENDPOINT <<<"${RESOLVED}"
OBJ_S3_ENDPOINT="${OBJ_S3_ENDPOINT:-}"

trap 'rm -f "${CSV_TMP}" "${SECRETS_TMP}"' EXIT

# Read existing rows so re-runs preserve buckets + keys (secret_key isn't recoverable).
# Plain indexed arrays (keyed by student number) — bash 3.2 has no associative arrays.
EXIST_BUCKET=(); EXIST_KEYID=(); EXIST_AK=(); EXIST_SK=()
if [[ -f "${CSV}" ]]; then
    while IFS=, read -r num bucket keyid ak sk || [[ -n "${num}" ]]; do
        [[ "${num}" == "student_number" ]] && continue
        [[ "${num}" =~ ^s([0-9]{2,})$ ]] || continue
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

    if [[ -n "${EXIST_AK[$i]:-}" ]]; then
        # Preserve: bucket + key already provisioned for this student.
        BUCKET="${EXIST_BUCKET[$i]}"
        KEY_ID="${EXIST_KEYID[$i]}"; ACCESS_KEY="${EXIST_AK[$i]}"; SECRET_KEY="${EXIST_SK[$i]}"
    else
        NEW=$((NEW+1))
        # Create the E3 bucket; the response carries the real S3 endpoint for this region.
        EP="$(obj_create_bucket "${OBJ_REGION}" "${BUCKET}")" || EP=""
        if [[ -n "${EP}" && -z "${OBJ_S3_ENDPOINT}" ]]; then
            OBJ_S3_ENDPOINT="${EP}"
        fi
        # Mint a LIMITED key locked to this single bucket (read_write).
        read -r KEY_ID ACCESS_KEY SECRET_KEY <<<"$(obj_create_key "$(key_label "${PADDED}")" "${OBJ_REGION}" "${BUCKET}" read_write)"
        if [[ -z "${ACCESS_KEY:-}" || -z "${SECRET_KEY:-}" ]]; then
            echo "ERROR: key create returned no key for student s${PADDED} (bucket ${BUCKET})." >&2
            exit 1
        fi
    fi

    echo "s${PADDED},${BUCKET},${KEY_ID},${ACCESS_KEY},${SECRET_KEY}" >> "${CSV_TMP}"
done

# The S3 endpoint: from the bucket-create response, else the endpoints listing, else the
# bucket listing (the API omits s3_endpoint until a bucket exists in the region).
if [[ -z "${OBJ_S3_ENDPOINT}" ]]; then
    OBJ_S3_ENDPOINT="$(obj_bucket_field "$(bucket_name 01)" s3_endpoint)"
fi
if [[ -z "${OBJ_S3_ENDPOINT}" ]]; then
    echo "ERROR: could not determine the ${OBJ_ENDPOINT_TYPE} S3 endpoint for region ${OBJ_REGION}." >&2
    exit 1
fi
ENDPOINT="https://${OBJ_S3_ENDPOINT}"

# Emit one Secret per student from the (now complete) CSV rows.
while IFS=, read -r num bucket keyid ak sk; do
    [[ "${num}" == "student_number" ]] && continue
    [[ "${num}" =~ ^s([0-9]{2,})$ ]] || continue
    PADDED="${BASH_REMATCH[1]}"
    i=$((10#${PADDED}))
    cat >> "${SECRETS_TMP}" << EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: ws-${PADDED}-object-storage
  namespace: $(student_ns "${PADDED}")
  labels:
    app: akamai-workshop-platform
    awp-student-number: "${i}"
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: "${ak}"
  AWS_SECRET_ACCESS_KEY: "${sk%$'\r'}"
  SESSION_BUCKET: "${bucket}"
  SESSION_ENDPOINT_URL: "${ENDPOINT}"
  SESSION_REGION: "${OBJ_REGION}"
EOF
done < "${CSV_TMP}"

mv "${CSV_TMP}" "${CSV}"
mv "${SECRETS_TMP}" "${SECRETS}"

echo ""
echo "=== Object Storage provisioned (region ${OBJ_REGION}, ${OBJ_ENDPOINT_TYPE} endpoint ${ENDPOINT}) ==="
if [[ ${NEW} -gt 0 ]]; then
    echo "Provisioned ${NEW} new bucket(s)+key(s); preserved $((COUNT-NEW)) existing."
else
    echo "Preserved ${COUNT} existing bucket(s)+key(s); re-emitted Secrets only."
fi
echo "Files:"
echo "  ${SECRETS}   (per-student Secret → env)"
echo "  ${CSV}       (bucket+key state — gitignored, NEVER commit)"
echo "Apply with: kubectl apply -f ${SECRETS}"
