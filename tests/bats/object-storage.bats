#!/usr/bin/env bats
# Phase 4: object_storage=managed. All offline against tests/fakes/linode-cli —
# per-student bucket + bucket-scoped key, idempotent re-run, teardown revoke+delete,
# region-id resolution, and the generate-pods envFrom wiring (default byte-identical).
# Real bucket/key provisioning is NOT in the paid smoke.
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

@test "provision mints a bucket-scoped key + Secret per student" {
  OUTPUT_DIR="${OUT}" run "${PROV}" -n 3 --region us-ord --prefix acme-2026
  [ "$status" -eq 0 ]
  # one keys-create + one buckets-create per student
  [ "$(grep -c 'object-storage keys-create' "${FAKE_LINODE_LOG}")" -eq 3 ]
  [ "$(grep -c 'object-storage buckets-create' "${FAKE_LINODE_LOG}")" -eq 3 ]
  # key is LIMITED to the single bucket (read_write) — the isolation guarantee
  assert_linode_called 'keys-create.*--bucket_access.bucket_name acme-2026-s01.*--bucket_access.permissions read_write'
  # Secret carries the SA-agent env vars
  f="${OUT}/workspace-object-storage.yaml"
  [ "$(grep -c '^kind: Secret' "$f")" -eq 3 ]
  grep -q 'name: ws-01-object-storage' "$f"
  grep -q 'AWS_ACCESS_KEY_ID: "FAKEACCESS"' "$f"
  grep -q 'AWS_SECRET_ACCESS_KEY: "FAKESECRET"' "$f"
  grep -q 'SESSION_BUCKET: "acme-2026-s01"' "$f"
  grep -q 'SESSION_REGION: "us-ord"' "$f"
}

@test "provision uses the REGION id (us-ord), never the cluster id (us-ord-1)" {
  OUTPUT_DIR="${OUT}" run "${PROV}" -n 1 --region us-ord --prefix acme-2026
  [ "$status" -eq 0 ]
  # bucket/key creation must carry the region id from the clusters-list `region` column
  assert_linode_called 'buckets-create --region us-ord '
  assert_linode_called 'keys-create.*--regions us-ord'
  ! grep -qE 'buckets-create --region us-ord-1' "${FAKE_LINODE_LOG}"
}

@test "provision resolves the region even if given the cluster id" {
  OUTPUT_DIR="${OUT}" run "${PROV}" -n 1 --region us-ord-1 --prefix acme-2026
  [ "$status" -eq 0 ]
  assert_linode_called 'buckets-create --region us-ord '
}

@test "provision fails on an unknown region" {
  export FAKE_OBJ_CLUSTERS='[{"id":"us-iad-1","region":"us-iad","status":"available"}]'
  OUTPUT_DIR="${OUT}" run "${PROV}" -n 1 --region eu-nowhere --prefix acme-2026
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found in object-storage clusters-list"* ]]
}

@test "provision requires --prefix (buckets are globally unique)" {
  OUTPUT_DIR="${OUT}" run "${PROV}" -n 1 --region us-ord
  [ "$status" -ne 0 ]
  [[ "$output" == *"--prefix is required"* ]]
}

@test "provision is idempotent: re-run preserves keys, creates nothing new" {
  OUTPUT_DIR="${OUT}" run "${PROV}" -n 2 --region us-ord --prefix acme-2026
  [ "$status" -eq 0 ]
  : > "${FAKE_LINODE_LOG}"
  OUTPUT_DIR="${OUT}" run "${PROV}" -n 2 --region us-ord --prefix acme-2026
  [ "$status" -eq 0 ]
  [ "$(grep -c 'keys-create' "${FAKE_LINODE_LOG}")" -eq 0 ]
  [ "$(grep -c 'buckets-create' "${FAKE_LINODE_LOG}")" -eq 0 ]
  [[ "$output" == *"Preserved 2"* ]]
}

@test "provision scoped places each Secret in the student namespace" {
  OUTPUT_DIR="${OUT}" run "${PROV}" -n 2 --region us-ord --prefix acme-2026 \
      --namespace workshop --cluster-access scoped
  [ "$status" -eq 0 ]
  grep -q 'namespace: workshop-s01' "${OUT}/workspace-object-storage.yaml"
  grep -q 'namespace: workshop-s02' "${OUT}/workspace-object-storage.yaml"
}

# --- teardown -----------------------------------------------------------------

@test "teardown revokes every key + empties/deletes every bucket by prefix" {
  OUTPUT_DIR="${OUT}" "${PROV}" -n 2 --region us-ord --prefix acme-2026 >/dev/null
  : > "${FAKE_LINODE_LOG}"
  export FAKE_OBJ_KEYS='[{"id":4242,"label":"acme-2026-s01-key"},{"id":4243,"label":"acme-2026-s02-key"},{"id":9,"label":"other-key"}]'
  export FAKE_OBJ_BUCKETS='[{"label":"acme-2026-s01"},{"label":"acme-2026-s02"},{"label":"someone-else-bucket"}]'
  OUTPUT_DIR="${OUT}" run "${PROV}" --teardown --region us-ord --prefix acme-2026
  [ "$status" -eq 0 ]
  # revokes only our two keys, not the unrelated one
  assert_linode_called 'object-storage keys-delete 4242'
  assert_linode_called 'object-storage keys-delete 4243'
  ! grep -qE 'keys-delete 9$' "${FAKE_LINODE_LOG}"
  # empties + deletes only our buckets, not the unrelated one
  assert_linode_called 'rb --recursive s3://acme-2026-s01'
  assert_linode_called 'object-storage buckets-delete us-ord acme-2026-s01'
  ! grep -q 'someone-else-bucket' "${FAKE_LINODE_LOG}"
  # local state removed
  [ ! -f "${OUT}/object-storage.csv" ]
}

@test "teardown is a clean no-op when nothing matches the prefix" {
  OUTPUT_DIR="${OUT}" run "${PROV}" --teardown --region us-ord --prefix acme-2026
  [ "$status" -eq 0 ]
  [ "$(grep -c 'keys-delete' "${FAKE_LINODE_LOG}")" -eq 0 ]
  [ "$(grep -c 'buckets-delete' "${FAKE_LINODE_LOG}")" -eq 0 ]
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
