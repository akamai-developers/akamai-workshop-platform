#!/usr/bin/env bats
# Phase 1: component flags round-trip through deploy.sh and validation rejects
# reserved / inconsistent values. All offline (dry-run; no token, no cloud).
load helper

setup() {
  DEPLOY="${REPO_ROOT}/deploy.sh"
  export NO_COLOR=1
}

# Render the dry-run preview for a given set of flags.
dry() { run "${DEPLOY}" deploy --dry-run --domain none "$@"; }

@test "default dry-run shows NO Components block (default shape unchanged)" {
  dry --students 80 --model Qwen/Qwen3-8B-FP8
  [ "$status" -eq 0 ]
  [[ "$output" != *"Components"* ]]
}

@test "every component flag round-trips into the preview" {
  dry --students 20 --model Qwen/Qwen3-4B-Instruct-2507 \
      --editor jupyter --inference dedicated-vllm --gpus-per-student 1 \
      --cluster-access scoped --object-storage managed --agent-deploy plain
  [ "$status" -eq 0 ]
  [[ "$output" == *"Components"* ]]
  [[ "$output" == *"jupyter"* ]]
  [[ "$output" == *"dedicated-vllm"* ]]
  [[ "$output" == *"scoped"* ]]
  [[ "$output" == *"managed"* ]]
  [[ "$output" == *"plain"* ]]
}

@test "config file sets components; flags override config" {
  cfg="${BATS_TEST_TMPDIR}/c.yaml"
  cat > "$cfg" <<EOF
students: 10
model: Qwen/Qwen3-4B-Instruct-2507
editor: jupyter
cluster_access: scoped
object_storage: managed
domain: none
EOF
  run "${DEPLOY}" deploy --dry-run --config "$cfg" --object-storage none
  [ "$status" -eq 0 ]
  [[ "$output" == *"jupyter"* ]]
  [[ "$output" == *"Object store:  none"* ]]
}

@test "reserved agent_deploy=kagent is rejected" {
  dry --agent-deploy kagent --cluster-access scoped
  [ "$status" -ne 0 ]
  [[ "$output" == *"kagent"* && "$output" == *"reserved"* ]]
}

@test "reserved gpus_per_student=2 is rejected" {
  dry --gpus-per-student 2
  [ "$status" -ne 0 ]
  [[ "$output" == *"reserved"* ]]
}

@test "agent_deploy=plain requires cluster_access=scoped" {
  dry --agent-deploy plain
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires cluster_access"* ]]
}

@test "unknown enum value is rejected" {
  dry --editor emacs
  [ "$status" -ne 0 ]
  [[ "$output" == *"editor must be"* ]]
}
