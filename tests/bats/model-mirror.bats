#!/usr/bin/env bats
# Model mirror: helm renders the aws-s3-sync initContainer + per-namespace read-only-key
# Secret when configured, and the default render is unchanged. mirror-models.sh validates
# args offline (before any network call).
load helper

setup() {
  HELM_DIR="${REPO_ROOT}/infra/helm"
  MIRROR="${REPO_ROOT}/infra/scripts/mirror-models.sh"
}

mirror_render() {
  helm template "${HELM_DIR}" --set inference=dedicated-vllm --set cluster_access=scoped \
    --set student_count=2 \
    --set model_mirror_bucket=acme-mirror \
    --set model_mirror_endpoint=https://us-sea-1.linodeobjects.com \
    --set model_mirror_region=us-sea \
    --set model_mirror_access_key=AKIA --set model_mirror_secret_key=SEKRET
}

@test "mirror renders an aws s3 sync initContainer per student (HF path bypassed)" {
  run mirror_render
  [ "$status" -eq 0 ]
  [ "$(grep -c 'name: pull-models-from-mirror' <<<"$output")" -eq 2 ]
  [[ "$output" == *"aws s3 sync"* ]]
  [[ "$output" == *"s3://acme-mirror/hf-cache"* ]]
  [[ "$output" != *"snapshot_download"* ]]
}

@test "mirror renders a read-only-key Secret per student namespace" {
  run mirror_render
  [ "$status" -eq 0 ]
  # Count only the Secret objects' metadata name (2-space indent), not the envFrom secretRef.
  [ "$(grep -cE '^  name: model-mirror-s3$' <<<"$output")" -eq 2 ]
  [[ "$output" == *"AWS_ACCESS_KEY_ID"* ]]
  [[ "$output" == *"namespace: workshop-s01"* ]]
}

@test "no mirror configured -> no mirror initContainer or Secret (default unchanged)" {
  run helm template "${HELM_DIR}" --set inference=dedicated-vllm --set cluster_access=scoped --set student_count=2
  [ "$status" -eq 0 ]
  [[ "$output" != *"pull-models-from-mirror"* ]]
  [[ "$output" != *"model-mirror-s3"* ]]
}

@test "mirror-models.sh requires --bucket" {
  run "${MIRROR}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--bucket is required"* ]]
}

@test "mirror-models.sh --help works offline" {
  run "${MIRROR}" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"mirror"* ]]
}
