#!/usr/bin/env bats
# Phase 5: inference = dedicated-vllm (1 GPU) | external + component-aware sizing.
# Offline: helm template (per-student vLLM / no-platform-vLLM), sizing.py, deploy.sh
# dry-run validation. Real GPU scheduling is NOT verifiable offline (pods stay Pending
# in kind) — it is covered by the Phase-7 smoke.
load helper

setup() {
  HELM_DIR="${REPO_ROOT}/infra/helm"
  SIZING="${REPO_ROOT}/infra/scripts/sizing.py"
  DEPLOY="${REPO_ROOT}/deploy.sh"
  export NO_COLOR=1
}

dry() { run "${DEPLOY}" deploy --dry-run --domain none "$@"; }

# --- helm: shared vLLM gating ------------------------------------------------

@test "default (shared-vllm) renders the shared vLLM StatefulSet" {
  run helm template "${HELM_DIR}"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^kind: StatefulSet' <<<"$output")" -eq 1 ]
  [[ "$output" == *"name: vllm"* ]]
}

@test "dedicated-vllm renders one per-student vLLM Deployment, no shared StatefulSet" {
  run helm template "${HELM_DIR}" --set inference=dedicated-vllm --set cluster_access=scoped --set student_count=3
  [ "$status" -eq 0 ]
  [[ "$output" != *"kind: StatefulSet"* ]]
  [ "$(grep -c '^kind: Deployment' <<<"$output")" -eq 3 ]
  [ "$(grep -c 'kind: PersistentVolumeClaim' <<<"$output")" -eq 3 ]
  # deliberately under-tuned, pinned to a GPU node, 1 GPU each
  [[ "$output" == *"--gpu-memory-utilization=0.4"* ]]
  [[ "$output" == *"--max-model-len=2048"* ]]
  [[ "$output" == *"pool: gpu"* ]]
  [[ "$output" == *"nvidia.com/gpu: 1"* ]]
  # Service named vllm so the in-namespace workspace short name resolves
  [[ "$output" == *"namespace: workshop-s01"* ]]
}

@test "dedicated-vllm renders nothing without scoped (needs per-student namespaces)" {
  run helm template "${HELM_DIR}" --set inference=dedicated-vllm --set student_count=2
  [ "$status" -eq 0 ]
  [[ "$output" != *"--gpu-memory-utilization=0.4"* ]]
}

@test "external renders no platform vLLM at all" {
  run helm template "${HELM_DIR}" --set inference=external --set cluster_access=scoped --set student_count=2
  [ "$status" -eq 0 ]
  [[ "$output" != *"kind: StatefulSet"* ]]
  # only the vllm-secrets Secret may mention vllm; no vLLM workload/Service
  ! grep -qE '^kind: Deployment' <<<"$output"
  ! grep -qE 'name: vllm$' <<<"$output"
}

# --- sizing.py component-aware -----------------------------------------------

@test "sizing dedicated-vllm: GPU nodes = students (not students/16)" {
  run python3 "${SIZING}" plan --students 10 --model Qwen/Qwen3-4B-Instruct-2507 \
      --inference dedicated-vllm --gpus-per-student 1 --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"gpu_node_count": 10'* ]]
  [[ "$output" == *'"gpu_node_type": "g2-gpu-rtx4000a1-s"'* ]]
}

@test "sizing external: zero GPU nodes, GPU cost omitted" {
  run python3 "${SIZING}" plan --students 20 --model Qwen/Qwen3-4B-Instruct-2507 \
      --inference external
  [ "$status" -eq 0 ]
  [[ "$output" == *"external inference endpoint"* ]]
  [[ "$output" == *"(CPU only)"* ]]
  [[ "$output" != *"GPU \$"* ]]
}

@test "sizing jupyter editor labels CPU nodes as workspaces" {
  run python3 "${SIZING}" plan --students 20 --model Qwen/Qwen3-4B-Instruct-2507 --editor jupyter
  [ "$status" -eq 0 ]
  [[ "$output" == *"(workspaces)"* ]]
  [[ "$output" != *"(code-servers)"* ]]
}

@test "sizing selftest still passes (incl. dedicated + external cases)" {
  run python3 "${SIZING}" selftest
  [ "$status" -eq 0 ]
  [[ "$output" == *"SELF-TEST PASSED"* ]]
}

# --- deploy.sh validation ----------------------------------------------------

@test "deploy rejects dedicated-vllm without scoped" {
  dry --students 4 --inference dedicated-vllm
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires cluster_access='scoped'"* ]]
}

@test "deploy rejects external without an endpoint" {
  dry --students 4 --inference external
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires --inference-endpoint"* ]]
}

@test "deploy external dry-run shows the endpoint and a CPU-only cost" {
  dry --students 8 --inference external --inference-endpoint https://api.example.com/v1
  [ "$status" -eq 0 ]
  [[ "$output" == *"external — https://api.example.com/v1"* ]]
  [[ "$output" == *"(CPU only)"* ]]
}
