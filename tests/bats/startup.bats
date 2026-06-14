#!/usr/bin/env bats
# Phase 2: startup.sh selects the right editor launch command from WORKSPACE_TYPE.
# Uses the WORKSPACE_PRINT_LAUNCH hook so no server is actually started.
load helper

STARTUP="${BATS_TEST_DIRNAME}/../../infra/images/workspace/startup.sh"

launch() { PASSWORD="pw123" WORKSPACE_PRINT_LAUNCH=1 run bash "$STARTUP"; }

@test "default editor launches code-server" {
  WORKSPACE_TYPE="" launch
  [ "$status" -eq 0 ]
  [[ "$output" == code-server* ]]
  [[ "$output" == *"--bind-addr 0.0.0.0:8080"* ]]
}

@test "code-server editor launches code-server" {
  WORKSPACE_TYPE=code-server launch
  [ "$status" -eq 0 ]
  [[ "$output" == code-server* ]]
}

@test "jupyter editor launches jupyter lab on 8080 with PASSWORD as token" {
  WORKSPACE_TYPE=jupyter launch
  [ "$status" -eq 0 ]
  [[ "$output" == "jupyter lab"* ]]
  [[ "$output" == *"--ServerApp.port=8080"* ]]
  [[ "$output" == *"--ServerApp.token=pw123"* ]]
}

@test "startup.sh parses as valid bash" {
  run bash -n "$STARTUP"
  [ "$status" -eq 0 ]
}
