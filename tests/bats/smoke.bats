#!/usr/bin/env bats
# Phase 0 smoke: the harness + fakes work, and the default offline gates pass.
load helper

@test "fake linode-cli is on PATH and logs invocations" {
  use_fakes
  run linode-cli object-storage clusters-list
  [ "$status" -eq 0 ]
  assert_linode_called "object-storage clusters-list"
}

@test "fake linode-cli can simulate an API failure" {
  use_fakes
  FAKE_LINODE_FAIL=4 run linode-cli object-storage keys-create --regions ""
  [ "$status" -eq 4 ]
}

@test "sizing.py selftest passes" {
  run python3 "${REPO_ROOT}/infra/scripts/sizing.py" selftest
  [ "$status" -eq 0 ]
  [[ "$output" == *"SELF-TEST PASSED"* ]]
}

@test "default helm template matches the golden snapshot" {
  run bash -c "helm template '${REPO_ROOT}/infra/helm' | diff - '${REPO_ROOT}/.build/golden/default-helm.yaml'"
  [ "$status" -eq 0 ]
}
