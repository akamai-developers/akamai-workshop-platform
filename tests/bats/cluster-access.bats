#!/usr/bin/env bats
# Phase 3: cluster_access=scoped + agent_deploy=plain. All offline (helm template,
# generate-pods.sh, generate-kubeconfig.sh against a fake kubectl). The kind+Cilium
# isolation + RBAC-Forbidden proofs live in tests/cilium-enforcement-check.sh and the
# Phase-3 fixtures (deferred while the host disk is full).
load helper

setup() {
  HELM_DIR="${REPO_ROOT}/infra/helm"
  GENPODS="${REPO_ROOT}/infra/scripts/generate-pods.sh"
  GENKUBE="${REPO_ROOT}/infra/scripts/generate-kubeconfig.sh"
  OUT="${BATS_TEST_TMPDIR}/out"
  mkdir -p "${OUT}"
}

# --- helm control-plane fence (Namespace/SA/Role/RoleBinding) -----------------

@test "default (cluster_access=none) renders no per-student namespaces/RBAC" {
  run helm template "${HELM_DIR}"
  [ "$status" -eq 0 ]
  [[ "$output" != *"awp-student"* ]]
  [[ "$output" != *"kind: Role"* ]]
}

@test "scoped renders a Namespace + ServiceAccount + Role + RoleBinding per student" {
  run helm template "${HELM_DIR}" --set cluster_access=scoped --set student_count=3
  [ "$status" -eq 0 ]
  # 3 per-student namespaces (plus the shared workshop namespace, not counted here).
  [ "$(grep -cE 'name: workshop-s[0-9]{2}$' <<<"$output")" -ge 3 ]
  [ "$(grep -c '^kind: ServiceAccount' <<<"$output")" -eq 3 ]
  [ "$(grep -c '^kind: Role$' <<<"$output")" -eq 3 ]
  [ "$(grep -c '^kind: RoleBinding' <<<"$output")" -eq 3 ]
  [[ "$output" == *"name: workshop-s01"* ]]
  [[ "$output" == *"name: workshop-s03"* ]]
}

@test "scoped Role has NO cluster-scoped verbs (no nodes/namespaces/rbac)" {
  run helm template "${HELM_DIR}" --set cluster_access=scoped --set student_count=1
  [ "$status" -eq 0 ]
  [[ "$output" != *"nodes"* ]]
  [[ "$output" != *"clusterroles"* ]]
  # The only namespaces in the render are the metadata objects, never an RBAC resource.
  ! grep -A8 'kind: Role$' <<<"$output" | grep -qE 'resources:.*namespaces'
}

# --- per-namespace NetworkPolicy data-plane fence -----------------------------

@test "scoped renders default-deny + scoped allow NetworkPolicies per student" {
  run helm template "${HELM_DIR}" --set cluster_access=scoped --set student_count=2
  [ "$status" -eq 0 ]
  [ "$(grep -c 'name: default-deny-ingress' <<<"$output")" -ge 2 ]
  [[ "$output" == *"allow-ingress-to-workspace"* ]]
  [[ "$output" == *"allow-workspace-to-vllm"* ]]
}

@test "agent_deploy adds an allow-ingress-to-agent policy; absent by default" {
  run helm template "${HELM_DIR}" --set cluster_access=scoped --set agent_deploy=plain --set student_count=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"allow-ingress-to-agent"* ]]

  run helm template "${HELM_DIR}" --set cluster_access=scoped --set student_count=1
  [[ "$output" != *"allow-ingress-to-agent"* ]]
}

# --- generate-pods.sh per-student-namespace mode ------------------------------

@test "generate-pods scoped puts each workspace in its own namespace + mounts kubeconfig" {
  OUTPUT_DIR="${OUT}" run "${GENPODS}" -n 2 --host fixed.example --cluster-access scoped
  [ "$status" -eq 0 ]
  grep -q 'namespace: workshop-s01' "${OUT}/workspace-manifests.yaml"
  grep -q 'namespace: workshop-s02' "${OUT}/workspace-manifests.yaml"
  grep -q 'mountPath: /home/coder/.kube' "${OUT}/workspace-manifests.yaml"
  grep -q 'secretName: ws-01-kubeconfig' "${OUT}/workspace-manifests.yaml"
  # per-student-namespace configmap + ingress
  grep -q 'namespace: workshop-s01' "${OUT}/workspace-startup-configmap.yaml"
  grep -q 'namespace: workshop-s02' "${OUT}/ingress.yaml"
}

@test "generate-pods default emits NO kubeconfig mount/volume (sentinels stripped)" {
  OUTPUT_DIR="${OUT}" run "${GENPODS}" -n 1 --host fixed.example
  [ "$status" -eq 0 ]
  [[ "$(cat "${OUT}/workspace-manifests.yaml")" != *"__KUBECONFIG"* ]]
  [[ "$(cat "${OUT}/workspace-manifests.yaml")" != *"/home/coder/.kube"* ]]
}

@test "generate-pods agent_deploy=plain emits an agent Deployment+Service + ingress host" {
  OUTPUT_DIR="${OUT}" run "${GENPODS}" -n 1 --host fixed.example --cluster-access scoped --agent-deploy plain
  [ "$status" -eq 0 ]
  grep -q '^kind: Deployment' "${OUT}/workspace-manifests.yaml"
  grep -qE 'name: agent$' "${OUT}/workspace-manifests.yaml"
  grep -q 'WORKSPACE_TYPE' "${OUT}/workspace-manifests.yaml"
  grep -q 'agent-s01.fixed.example' "${OUT}/ingress.yaml"
}

@test "generate-pods rejects agent_deploy=plain without scoped" {
  OUTPUT_DIR="${OUT}" run "${GENPODS}" -n 1 --host fixed.example --agent-deploy plain
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires --cluster-access scoped"* ]]
}

# --- generate-kubeconfig.sh (fake kubectl) ------------------------------------

@test "generate-kubeconfig mints a namespace-scoped kubeconfig Secret per student" {
  OUTPUT_DIR="${OUT}" KUBECTL="${FAKES_DIR}/kubectl" run "${GENKUBE}" -n 2 --namespace workshop
  [ "$status" -eq 0 ]
  f="${OUT}/workspace-kubeconfigs.yaml"
  [ "$(grep -c '^kind: Secret' "$f")" -eq 2 ]
  grep -q 'name: ws-01-kubeconfig' "$f"
  grep -q 'namespace: workshop-s01' "$f"
  grep -q 'current-context: workshop-s01' "$f"
  # The operator admin kubeconfig is never embedded — only a scoped SA token.
  grep -q 'token: faketoken.workshop-s01' "$f"
  [[ "$(cat "$f")" != *"client-certificate"* ]]
}

# --- shared-vllm + scoped cross-namespace reachability (Phase 8 fix) -----------

@test "scoped: shared vLLM policy admits workspaces from per-student namespaces" {
  run helm template "${HELM_DIR}" --set cluster_access=scoped --set student_count=1
  [ "$status" -eq 0 ]
  # allow-workspaces-to-vllm must accept ingress from awp-student=true namespaces,
  # else shared-vllm + scoped workspaces (the SA preset) can't reach the model.
  echo "$output" | awk '/name: allow-workspaces-to-vllm/,/port: 8000/' | grep -q 'awp-student: "true"'
}

@test "default (cluster_access=none) vLLM policy has NO cross-namespace selector" {
  run helm template "${HELM_DIR}"
  [ "$status" -eq 0 ]
  ! { echo "$output" | awk '/name: allow-workspaces-to-vllm/,/port: 8000/' | grep -q 'awp-student'; }
}
