#!/usr/bin/env bash
# obj-storage-lib.sh — shared Linode Object Storage helpers for the platform scripts.
# Sourced by provision-object-storage.sh and mirror-models.sh; not executable on its own.
#
# Everything goes through the Linode REST API with curl + python3 stdlib. No linode-cli
# (its version banner and the removed `buckets-*` actions broke the old path) and no
# boto3.
#
# POLICY (2026-11-07): E3 endpoints only, and never a bucket in us-sea.
#   - E3 is the current Object Storage generation. Its hostnames differ from E0/E1
#     (us-ord-10.linodeobjects.com vs us-sea-1.linodeobjects.com), so the S3 endpoint is
#     always read back from the API, never guessed from "<region>-1".
#   - us-sea has no E3 endpoint and this account does not use it for storage. GPU nodes
#     in us-sea are fine; buckets for a us-sea cluster go to another region (us-ord).
#
# Overridable for offline tests: OBJ_API (tests/fakes/curl answers it), OBJ_DENY_REGIONS.

OBJ_API="${OBJ_API:-https://api.linode.com/v4/object-storage}"
OBJ_ENDPOINT_TYPE="${OBJ_ENDPOINT_TYPE:-E3}"
OBJ_DENY_REGIONS="${OBJ_DENY_REGIONS:-us-sea}"

obj_token() { printf '%s' "${LINODE_CLI_TOKEN:-${TF_VAR_token:-${LINODE_TOKEN:-}}}"; }

# obj_api METHOD PATH [JSON_BODY] -> prints the response body, then the HTTP status code
# on its own last line (split them with obj_body / obj_code).
obj_api() {
    local method="$1" path="$2" body="${3:-}"
    if [[ -n "$body" ]]; then
        curl -s -w $'\n%{http_code}' -X "$method" "${OBJ_API}${path}" \
            -H "Authorization: Bearer $(obj_token)" -H "Content-Type: application/json" \
            -d "$body"
    else
        curl -s -w $'\n%{http_code}' -X "$method" "${OBJ_API}${path}" \
            -H "Authorization: Bearer $(obj_token)"
    fi
}
obj_body() { printf '%s\n' "$1" | sed '$d'; }
obj_code() { printf '%s\n' "$1" | tail -n1; }

# obj_region_denied REGION -> 0 when the region is off limits for Object Storage.
obj_region_denied() { [[ " ${OBJ_DENY_REGIONS} " == *" $1 "* ]]; }

# obj_py JSON SCRIPT [ARGS...] -> run a python3 snippet with the JSON on stdin, so bucket
# and key listings for 200 students never hit the argv size limit.
obj_py() {
    local json="$1" script="$2"; shift 2
    printf '%s' "$json" | python3 -c "$script" "$@"
}

# obj_resolve_endpoint REGION -> prints "<region> <s3_endpoint>" for the E3 endpoint in
# that region (s3_endpoint may be empty until the first bucket exists there). Accepts a
# legacy cluster id (us-ord-1) or endpoint prefix (us-ord-10) and resolves it to the
# region. Returns 1 with a message on stderr when the region is denied or has no E3
# endpoint.
obj_resolve_endpoint() {
    local want="$1" json
    if obj_region_denied "$want"; then
        echo "ERROR: region '${want}' is not allowed for Object Storage (policy: ${OBJ_ENDPOINT_TYPE} endpoints only, never ${OBJ_DENY_REGIONS}). Use an ${OBJ_ENDPOINT_TYPE} region such as us-ord; GPU nodes may still run in ${want}." >&2
        return 1
    fi
    json="$(obj_body "$(obj_api GET "/endpoints?page_size=500")")"
    obj_py "$json" '
import json, re, sys
want, etype = sys.argv[1], sys.argv[2]
try:
    parsed = json.load(sys.stdin)
    data = parsed.get("data", []) if isinstance(parsed, dict) else parsed
except Exception:
    data = []
rows = [r for r in data if r.get("endpoint_type") == etype]
cands = [want]
m = re.match(r"^(.*)-\d+$", want)
if m:
    cands.append(m.group(1))
for c in cands:
    for r in rows:
        if r.get("region") == c:
            print(c, r.get("s3_endpoint") or "")
            sys.exit(0)
avail = ", ".join(sorted(r.get("region", "") for r in rows)) or "(none listed)"
sys.stderr.write(f"ERROR: region {want!r} has no {etype} Object Storage endpoint. {etype} regions: {avail}\n")
sys.exit(1)
' "$want" "$OBJ_ENDPOINT_TYPE"
}

# obj_create_bucket REGION LABEL -> prints the bucket's s3_endpoint (empty if the API
# omits it). Idempotent: a bucket you already own returns 2xx. Returns 1 on an API error.
obj_create_bucket() {
    local region="$1" label="$2" resp code body
    resp="$(obj_api POST "/buckets" "{\"label\":\"${label}\",\"region\":\"${region}\",\"endpoint_type\":\"${OBJ_ENDPOINT_TYPE}\"}")"
    code="$(obj_code "$resp")"; body="$(obj_body "$resp")"
    case "$code" in
        2*) obj_py "$body" '
import json, sys
try:
    d = json.load(sys.stdin)
    d = d[0] if isinstance(d, list) else d
    print(d.get("s3_endpoint") or "")
except Exception:
    print("")
'
            return 0 ;;
        *)  echo "  WARN: bucket create ${label} (region ${region}, ${OBJ_ENDPOINT_TYPE}) returned HTTP ${code}: ${body}" >&2
            return 1 ;;
    esac
}

# obj_list_buckets -> raw JSON of every bucket the token owns ({"data": [...]}).
obj_list_buckets() { obj_body "$(obj_api GET "/buckets?page_size=500")"; }

# obj_bucket_field LABEL FIELD -> that field of the named bucket, from the bucket list.
obj_bucket_field() {
    obj_py "$(obj_list_buckets)" '
import json, sys
label, field = sys.argv[1], sys.argv[2]
try:
    parsed = json.load(sys.stdin)
    data = parsed.get("data", []) if isinstance(parsed, dict) else parsed
except Exception:
    data = []
for b in data:
    if b.get("label") == label:
        print(b.get(field) or "")
        break
' "$1" "$2"
}

# obj_delete_bucket REGION LABEL (best-effort; the API refuses a non-empty bucket).
obj_delete_bucket() { obj_api DELETE "/buckets/$1/$2" >/dev/null 2>&1 || true; }

# obj_create_key LABEL REGION BUCKET PERMISSIONS -> prints "<id> <access_key> <secret_key>".
# A LIMITED key, valid for exactly one bucket in one region. All fields empty on failure.
obj_create_key() {
    local label="$1" region="$2" bucket="$3" perms="$4" resp
    resp="$(obj_api POST "/keys" "{\"label\":\"${label}\",\"bucket_access\":[{\"region\":\"${region}\",\"bucket_name\":\"${bucket}\",\"permissions\":\"${perms}\"}]}")"
    obj_py "$(obj_body "$resp")" '
import json, sys
try:
    d = json.load(sys.stdin)
    k = d[0] if isinstance(d, list) else d
    print(k.get("id", ""), k.get("access_key", ""), k.get("secret_key", ""))
except Exception:
    print("", "", "")
'
}

# obj_list_keys -> raw JSON of every access key ({"data": [...]}).
obj_list_keys() { obj_body "$(obj_api GET "/keys?page_size=500")"; }

# obj_delete_key ID (best-effort).
obj_delete_key() { obj_api DELETE "/keys/$1" >/dev/null 2>&1 || true; }
