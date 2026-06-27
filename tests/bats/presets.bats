#!/usr/bin/env bats
# Phase 8: workshop presets in the wizard + the embedding model. All offline (dry-run
# previews and generate-pods.sh renders; no token, no cloud).
load helper

setup() {
  DEPLOY="${REPO_ROOT}/deploy.sh"
  SIZING="${REPO_ROOT}/infra/scripts/sizing.py"
  GENPODS="${REPO_ROOT}/infra/scripts/generate-pods.sh"
  OUT="${BATS_TEST_TMPDIR}/out"
  mkdir -p "${OUT}"
  export NO_COLOR=1
}

# Render the dry-run preview for a given set of flags.
dry() { run "${DEPLOY}" deploy --dry-run --domain none "$@"; }

# --- the catalog gained the two workshop models --------------------------------

@test "catalog lists Qwen2.5-7B-Instruct and the bge embedding model" {
  run python3 "${SIZING}" catalog
  [ "$status" -eq 0 ]
  [[ "$output" == *"Qwen/Qwen2.5-7B-Instruct"* ]]
  [[ "$output" == *"BAAI/bge-large-en-v1.5"* ]]
  [[ "$output" == *"embedding"* ]]
}

@test "models-info classifies chat vs embedding" {
  run python3 "${SIZING}" models-info --models "Qwen/Qwen2.5-7B-Instruct,BAAI/bge-large-en-v1.5"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CHAT_MODELS='Qwen/Qwen2.5-7B-Instruct'"* ]]
  [[ "$output" == *"EMBEDDING_MODELS='BAAI/bge-large-en-v1.5'"* ]]
}

# --- presets resolve in the dry-run preview ------------------------------------

@test "preset solution-architect-agent resolves to the full SA composition" {
  dry --preset solution-architect-agent --students 20
  [ "$status" -eq 0 ]
  [[ "$output" == *"Qwen/Qwen2.5-7B-Instruct"* ]]
  [[ "$output" == *"akamai-workshop-solution-architect-agent"* ]]
  [[ "$output" == *"Components"* ]]
  [[ "$output" == *"jupyter"* ]]
  [[ "$output" == *"scoped"* ]]
  [[ "$output" == *"managed"* ]]
  [[ "$output" == *"plain"* ]]
}

@test "preset ai-agents keeps the original default shape (NO Components block)" {
  dry --preset ai-agents --students 80
  [ "$status" -eq 0 ]
  [[ "$output" == *"Qwen/Qwen3-8B-FP8"* ]]
  [[ "$output" != *"Components"* ]]
}

@test "preset own-inference is jupyter + dedicated-vllm + scoped + FP8 model + pre-cache" {
  dry --preset own-inference --students 12
  [ "$status" -eq 0 ]
  [[ "$output" == *"dedicated-vllm"* ]]
  [[ "$output" == *"jupyter"* ]]
  [[ "$output" == *"scoped"* ]]
  [[ "$output" == *"RedHatAI/Qwen3-4B-FP8-dynamic"* ]]
  [[ "$output" == *"Pre-cache:"* ]]
}

@test "explicit --model overrides the own-inference preset's FP8 default" {
  dry --preset own-inference --students 4 --model Qwen/Qwen3-0.6B
  [ "$status" -eq 0 ]
  [[ "$output" == *"Qwen/Qwen3-0.6B"* ]]
}

@test "explicit flags override a preset" {
  dry --preset solution-architect-agent --editor code-server --students 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"Editor:"*"code-server"* ]]
}

@test "preset works as a config key" {
  cfg="${BATS_TEST_TMPDIR}/p.yaml"
  cat > "$cfg" <<EOF
students: 20
preset: solution-architect-agent
domain: none
EOF
  run "${DEPLOY}" deploy --dry-run --config "$cfg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"jupyter"* ]]
  [[ "$output" == *"Qwen/Qwen2.5-7B-Instruct"* ]]
}

@test "unknown preset is rejected" {
  dry --preset bogus --students 5
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown preset"* ]]
}

# --- embedding model: paired, never standalone ---------------------------------

@test "chat + embedding deploys both behind the gateway" {
  dry --students 20 --model "Qwen/Qwen2.5-7B-Instruct,BAAI/bge-large-en-v1.5"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BAAI/bge-large-en-v1.5"* ]]
  [[ "$output" == *"agentgateway"* ]]
}

@test "an embedding-only selection is rejected" {
  dry --students 20 --model "BAAI/bge-large-en-v1.5"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no chat model"* ]]
}

# --- workspace env wiring (generate-pods.sh) -----------------------------------

@test "jupyter workspace gets VLLM_BASE_URL / VLLM_MODEL_ID aliases" {
  OUTPUT_DIR="${OUT}" run "${GENPODS}" -n 1 --host fixed.example \
    --workspace-type jupyter --model Qwen/Qwen2.5-7B-Instruct --vllm-host http://vllm:8000/v1
  [ "$status" -eq 0 ]
  grep -q 'name: VLLM_BASE_URL' "${OUT}/workspace-manifests.yaml"
  grep -q 'name: VLLM_MODEL_ID' "${OUT}/workspace-manifests.yaml"
  # exactly one each (no duplicate / misplaced block)
  [ "$(grep -c 'name: VLLM_BASE_URL' "${OUT}/workspace-manifests.yaml")" -eq 1 ]
}

@test "default code-server workspace has NO alias env (sentinel stripped)" {
  OUTPUT_DIR="${OUT}" run "${GENPODS}" -n 1 --host fixed.example
  [ "$status" -eq 0 ]
  ! grep -q 'name: VLLM_BASE_URL' "${OUT}/workspace-manifests.yaml"
  ! grep -q 'name: EMBEDDING_BASE_URL' "${OUT}/workspace-manifests.yaml"
  # and no leftover awk sentinels
  ! grep -qE '__[A-Z_]+__' "${OUT}/workspace-manifests.yaml"
}

@test "an embedding model wires EMBEDDING_BASE_URL / EMBEDDING_MODEL_ID" {
  OUTPUT_DIR="${OUT}" run "${GENPODS}" -n 1 --host fixed.example \
    --workspace-type jupyter --model Qwen/Qwen2.5-7B-Instruct \
    --embedding-model BAAI/bge-large-en-v1.5 --vllm-host http://agentgateway:8080/v1
  [ "$status" -eq 0 ]
  grep -q 'name: EMBEDDING_BASE_URL' "${OUT}/workspace-manifests.yaml"
  grep -q 'value: "BAAI/bge-large-en-v1.5"' "${OUT}/workspace-manifests.yaml"
}
