#!/usr/bin/env bats
# Phase 4: object_storage=managed. All offline against tests/fakes/curl (the Linode REST
# API) — per-student E3 bucket + bucket-scoped key, idempotent re-run, teardown
# revoke+delete, E3-only / never-us-sea policy, and the generate-pods envFrom wiring
# (default byte-identical). Real bucket/key provisioning is NOT in the paid smoke.
load helper

setup() {
  use_fakes
  PROV="${REPO_ROOT}/infra/scripts/provision-object-storage.sh"
  GENPODS="${REPO_ROOT}/infra/scripts/generate-pods.sh"
  OUT="${BATS_TEST_TMPDIR}/out"
  mkdir -p "${OUT}"
  export LINODE_CLI_TOKEN=faketoken
}

# --- provisioning -------------------------------------------------------------

@test "provision mints an E3 bucket + bucket-scoped key + Secret per student" {
  OUTPUT_DIR="${OUT}" run "${PROV}" -n 3 --region us-ord --prefix acme-2026
  [ "$status" -eq 0 ]
  # one bucket POST + one key POST (REST API via curl) per student
  [ "$(grep -c -- '-X POST .*object-storage/buckets' "${FAKE_CURL_LOG}")" -eq 3 ]
  [ "$(grep -c -- '-X POST .*object-storage/keys' "${FAKE_CURL_LOG}")" -eq 3 ]
  # every bucket is created on the E3 endpoint type, never E0/E1
  [ "$(grep -c '"endpoint_type":"E3"' "${FAKE_CURL_LOG}")" -eq 3 ]
  # key is LIMITED to the single bucket (read_write) — the isolation guarantee
  grep -q '"bucket_name":"acme-2026-s01","permissions":"read_write"' "${FAKE_CURL_LOG}"
  # Secret carries the SA-agent env vars
  f="${OUT}/workspace-object-storage.yaml"
  [ "$(grep -c '^kind: Secret' "$f")" -eq 3 ]
  grep -q 'name: ws-01-object-storage' "$f"
  grep -q 'AWS_ACCESS_KEY_ID: "FAKEACCESS"' "$f"
  grep -q 'AWS_SECRET_ACCESS_KEY: "FAKESECRET"' "$f"
  grep -q 'SESSION_BUCKET: "acme-2026-s01"' "$f"
  grep -q 'SESSION_REGION: "us-ord"' "$f"
  # the S3 endpoint is the E3 hostname the API returned, not a guessed "<region>-1"
  grep -q 'SESSION_ENDPOINT_URL: "https://us-ord-10.linodeobjects.com"' "$f"
  ! grep -q 'us-ord-1.linodeobjects.com' "$f"
}

@test "provision uses the REGION id (us-ord) in bucket and key payloads" {
  OUTPUT_DIR="${OUT}" run "${PROV}" -n 1 --region us-ord --prefix acme-2026
  [ "$status" -eq 0 ]
  grep -q '"region":"us-ord","endpoint_type":"E3"' "${FAKE_CURL_LOG}"
  grep -q '"bucket_access":\[{"region":"us-ord"' "${FAKE_CURL_LOG}"
  ! grep -q '"region":"us-ord-1"' "${FAKE_CURL_LOG}"
}

@test "provision resolves the region even if given a legacy cluster id" {
  OUTPUT_DIR="${OUT}" run "${PROV}" -n 1 --region us-ord-1 --prefix acme-2026
  [ "$status" -eq 0 ]
  grep -q '"region":"us-ord","endpoint_type":"E3"' "${FAKE_CURL_LOG}"
}

@test "provision fails on a region with no E3 endpoint (creates nothing)" {
  OUTPUT_DIR="${OUT}" run "${PROV}" -n 1 --region us-iad --prefix acme-2026
  [ "$status" -ne 0 ]
  [[ "$output" == *"no E3 Object Storage endpoint"* ]]
  [ "$(grep -c -- '-X POST' "${FAKE_CURL_LOG}")" -eq 0 ]
}

@test "provision refuses us-sea for Object Storage (policy; no API call made)" {
  OUTPUT_DIR="${OUT}" run "${PROV}" -n 1 --region us-sea --prefix acme-2026
  [ "$status" -ne 0 ]
  [[ "$output" == *"not allowed for Object Storage"* ]]
  [ "$(grep -c -- '-X POST' "${FAKE_CURL_LOG}")" -eq 0 ]
}

@test "provision requires --prefix (buckets are globally unique)" {
  OUTPUT_DIR="${OUT}" run "${PROV}" -n 1 --region us-ord
  [ "$status" -ne 0 ]
  [[ "$output" == *"--prefix is required"* ]]
}

@test "provision is idempotent: re-run preserves keys, creates nothing new" {
  OUTPUT_DIR="${OUT}" run "${PROV}" -n 2 --region us-ord --prefix acme-2026
  [ "$status" -eq 0 ]
  : > "${FAKE_CURL_LOG}"
  OUTPUT_DIR="${OUT}" run "${PROV}" -n 2 --region us-ord --prefix acme-2026
  [ "$status" -eq 0 ]
  [ "$(grep -c -- '-X POST' "${FAKE_CURL_LOG}")" -eq 0 ]
  [[ "$output" == *"Preserved 2"* ]]
  grep -q 'SESSION_ENDPOINT_URL: "https://us-ord-10.linodeobjects.com"' "${OUT}/workspace-object-storage.yaml"
}

@test "provision scoped places each Secret in the student namespace" {
  OUTPUT_DIR="${OUT}" run "${PROV}" -n 2 --region us-ord --prefix acme-2026 \
      --namespace workshop --cluster-access scoped
  [ "$status" -eq 0 ]
  grep -q 'namespace: workshop-s01' "${OUT}/workspace-object-storage.yaml"
  grep -q 'namespace: workshop-s02' "${OUT}/workspace-object-storage.yaml"
}

# --- teardown -----------------------------------------------------------------

@test "teardown revokes every key + empties/deletes every bucket by prefix, in the bucket's own region" {
  OUTPUT_DIR="${OUT}" run "${PROV}" -n 2 --region us-ord --prefix acme-2026
  : > "${FAKE_CURL_LOG}"
  export FAKE_S3_LOG="${BATS_TEST_TMPDIR}/s3.log"; : > "${FAKE_S3_LOG}"
  export S3_EMPTY="${FAKES_DIR}/s3-empty"
  export FAKE_OBJ_KEYS='{"data":[{"id":4242,"label":"acme-2026-s01-key"},{"id":4243,"label":"acme-2026-s02-key"},{"id":9,"label":"other-key"}]}'
  export FAKE_OBJ_BUCKETS='{"data":[{"label":"acme-2026-s01","region":"us-ord","s3_endpoint":"us-ord-10.linodeobjects.com"},{"label":"acme-2026-s02","region":"us-ord","s3_endpoint":"us-ord-10.linodeobjects.com"},{"label":"someone-else-bucket","region":"us-ord","s3_endpoint":"us-ord-10.linodeobjects.com"}]}'
  # no --region: teardown finds each bucket's region from the API listing
  OUTPUT_DIR="${OUT}" run "${PROV}" --teardown --prefix acme-2026
  [ "$status" -eq 0 ]
  # revokes only our two keys, not the unrelated one
  grep -q -- '-X DELETE .*object-storage/keys/4242' "${FAKE_CURL_LOG}"
  grep -q -- '-X DELETE .*object-storage/keys/4243' "${FAKE_CURL_LOG}"
  ! grep -qE 'object-storage/keys/9( |$)' "${FAKE_CURL_LOG}"
  # empties (stdlib SigV4 s3.py, against the E3 endpoint) + deletes only our buckets
  grep -q -- '--bucket acme-2026-s01' "${FAKE_S3_LOG}"
  grep -q -- '--endpoint https://us-ord-10.linodeobjects.com' "${FAKE_S3_LOG}"
  grep -q -- '-X DELETE .*object-storage/buckets/us-ord/acme-2026-s01' "${FAKE_CURL_LOG}"
  ! grep -q 'someone-else-bucket' "${FAKE_S3_LOG}"
  ! grep -q 'someone-else-bucket' "${FAKE_CURL_LOG}"
  # local state removed
  [ ! -f "${OUT}/object-storage.csv" ]
}

@test "teardown is a clean no-op when nothing matches the prefix" {
  OUTPUT_DIR="${OUT}" run "${PROV}" --teardown --prefix acme-2026
  [ "$status" -eq 0 ]
  [ "$(grep -c -- '-X DELETE' "${FAKE_CURL_LOG}")" -eq 0 ]
}

# --- generate-pods envFrom wiring ---------------------------------------------

@test "generate-pods managed wires the object-storage Secret as envFrom" {
  OUTPUT_DIR="${OUT}" run "${GENPODS}" -n 1 --host fixed.example --object-storage managed
  [ "$status" -eq 0 ]
  grep -q 'envFrom:' "${OUT}/workspace-manifests.yaml"
  grep -q 'name: ws-01-object-storage' "${OUT}/workspace-manifests.yaml"
  grep -q 'optional: true' "${OUT}/workspace-manifests.yaml"
}

@test "generate-pods default emits NO object-storage envFrom (sentinel stripped)" {
  OUTPUT_DIR="${OUT}" run "${GENPODS}" -n 1 --host fixed.example
  [ "$status" -eq 0 ]
  [[ "$(cat "${OUT}/workspace-manifests.yaml")" != *"__OBJECT_STORAGE"* ]]
  [[ "$(cat "${OUT}/workspace-manifests.yaml")" != *"object-storage"* ]]
}

@test "generate-pods rejects an invalid --object-storage value" {
  OUTPUT_DIR="${OUT}" run "${GENPODS}" -n 1 --host fixed.example --object-storage bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"--object-storage must be"* ]]
}
