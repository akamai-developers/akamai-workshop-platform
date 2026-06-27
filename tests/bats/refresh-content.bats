#!/usr/bin/env bats
# refresh-content.sh: pull the latest content repo into every running workspace pod.
# Offline — uses the fake kubectl (FAKE_WORKSPACE_PODS feeds it a pod list).
load helper

setup() {
  use_fakes
  export FAKE_KUBECTL_LOG="${BATS_TEST_TMPDIR}/kubectl.log"
  : > "${FAKE_KUBECTL_LOG}"
  REFRESH="${REPO_ROOT}/infra/scripts/refresh-content.sh"
}

@test "force-updates every student workspace to the content ref" {
  export FAKE_WORKSPACE_PODS=$'workshop-s01/ws-01\nworkshop-s02/ws-02\n'
  run "${REFRESH}" --ref main
  [ "$status" -eq 0 ]
  grep -qE "get pods .*-l app=workspace" "${FAKE_KUBECTL_LOG}"
  grep -qE "workshop-s01 exec ws-01" "${FAKE_KUBECTL_LOG}"
  grep -qE "workshop-s02 exec ws-02" "${FAKE_KUBECTL_LOG}"
  grep -qE "git fetch --depth=1 origin .main" "${FAKE_KUBECTL_LOG}"
  grep -qE "git checkout -q -f FETCH_HEAD" "${FAKE_KUBECTL_LOG}"
}

@test "--keep-edits uses a fast-forward-only pull" {
  export FAKE_WORKSPACE_PODS=$'workshop-s01/ws-01\n'
  run "${REFRESH}" --keep-edits
  [ "$status" -eq 0 ]
  grep -qE "git pull --ff-only origin .main" "${FAKE_KUBECTL_LOG}"
}

@test "fails clearly when no workspace pods are found" {
  # FAKE_WORKSPACE_PODS unset -> fake get returns nothing (wrong cluster / not deployed)
  run "${REFRESH}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No workspace pods found"* ]]
}

@test "only touches pods in the given classroom namespace" {
  export FAKE_WORKSPACE_PODS=$'workshop-s01/ws-01\nother-class-s01/ws-01\nworkshop-staging/ws-09\n'
  run "${REFRESH}" --namespace workshop
  [ "$status" -eq 0 ]
  grep -qE "workshop-s01 exec ws-01" "${FAKE_KUBECTL_LOG}"
  # a different classroom and a look-alike (workshop-staging, not -sNN) are skipped
  ! grep -qE "other-class-s01 exec" "${FAKE_KUBECTL_LOG}"
  ! grep -qE "workshop-staging exec" "${FAKE_KUBECTL_LOG}"
}
