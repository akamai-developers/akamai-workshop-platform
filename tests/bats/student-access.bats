#!/usr/bin/env bats
load helper

setup() {
  GENPODS="${REPO_ROOT}/infra/scripts/generate-pods.sh"
  DEPLOY="${REPO_ROOT}/deploy.sh"
  OUT="${BATS_TEST_TMPDIR}/generated"
  export NO_COLOR=1
}

render() {
  run env OUTPUT_DIR="${OUT}" "${GENPODS}" -n 3 --host workshop.example.test "$@"
}

@test "portal is the default and emits one complete join service" {
  render
  [ "$status" -eq 0 ]
  [ -f "${OUT}/student-access.yaml" ]
  grep -q 'name: join-portal-data' "${OUT}/student-access.yaml"
  grep -q 'type: Recreate' "${OUT}/student-access.yaml"
  grep -q 'host: join.workshop.example.test' "${OUT}/student-access.yaml"
  grep -q 'name: allow-ingress-to-join-portal' "${OUT}/student-access.yaml"
  grep -q 'runAsNonRoot: true' "${OUT}/student-access.yaml"
  grep -q 'automountServiceAccountToken: false' "${OUT}/student-access.yaml"
}

@test "join portal uses the same TLS secret and HTTPS redirect as workspaces" {
  render --tls-secret classroom-tls
  [ "$status" -eq 0 ]
  for ingress in "${OUT}/student-access.yaml" "${OUT}/ingress.yaml"; do
    grep -q 'secretName: classroom-tls' "$ingress"
    grep -q 'nginx.ingress.kubernetes.io/force-ssl-redirect: "true"' "$ingress"
  done
  grep -q '        - join.workshop.example.test' "${OUT}/student-access.yaml"
  grep -q '        - s01.workshop.example.test' "${OUT}/ingress.yaml"

  render --tls-secret classroom-tls --cluster-access scoped --namespace classroom
  [ "$status" -eq 0 ]
  grep -q 'secretName: classroom-tls' "${OUT}/student-access.yaml"
  [ "$(grep -c 'secretName: classroom-tls' "${OUT}/ingress.yaml")" -eq 3 ]
}

@test "portal image is versioned and pinned by multi-arch digest" {
  render
  [ "$status" -eq 0 ]
  grep -q 'ghcr.io/muchobien/pocketbase:0.40.4@sha256:9390b7b63ce114dbab577be72e6ef75f718a19083866607fcbdd1b915632b943' \
    "${OUT}/student-access.yaml"
  ! grep -q 'pocketbase:latest' "${OUT}/student-access.yaml"
}

@test "slot inventory contains every generated workspace credential" {
  render
  [ "$status" -eq 0 ]
  python3 - "${OUT}/student-access.yaml" "${OUT}/access-cards.csv" <<'PY'
import base64, csv, json, re, sys
manifest = open(sys.argv[1]).read()
encoded = re.search(r"^  slots.json: (.+)$", manifest, re.MULTILINE).group(1)
slots = json.loads(base64.b64decode(encoded))
with open(sys.argv[2], newline="") as f:
    cards = list(csv.DictReader(f))
assert len(slots) == len(cards) == 3
for slot, card in zip(slots, cards):
    assert slot["student_number"] == card["student_number"]
    assert slot["workspace_url"] == card["url"]
    assert slot["workspace_password"] == card["password"]
PY
}

@test "rerender preserves the generated portal administrator password" {
  render
  [ "$status" -eq 0 ]
  first="$(grep '^  PB_ADMIN_PASSWORD:' "${OUT}/student-access.yaml")"

  render
  [ "$status" -eq 0 ]
  second="$(grep '^  PB_ADMIN_PASSWORD:' "${OUT}/student-access.yaml")"
  [ "$first" = "$second" ]
}

@test "cards mode emits no portal manifest" {
  render --student-access cards
  [ "$status" -eq 0 ]
  [ ! -e "${OUT}/student-access.yaml" ]
  [ -f "${OUT}/access-cards.csv" ]
}

@test "portal stays in the base namespace when workspaces are scoped" {
  render --cluster-access scoped --namespace classroom
  [ "$status" -eq 0 ]
  grep -q 'namespace: classroom' "${OUT}/student-access.yaml"
  ! grep -q 'namespace: classroom-s01' "${OUT}/student-access.yaml"
}

@test "invalid student access mode is rejected" {
  render --student-access magic
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be 'portal' or 'cards'"* ]]
}

@test "deploy dry-run reports portal default and accepts cards override" {
  run "${DEPLOY}" deploy --dry-run --domain none --students 3 --model Qwen/Qwen3-4B-Instruct-2507
  [ "$status" -eq 0 ]
  [[ "$output" == *"self-registration portal + card fallback"* ]]

  run "${DEPLOY}" deploy --dry-run --domain none --students 3 \
    --model Qwen/Qwen3-4B-Instruct-2507 --student-access cards
  [ "$status" -eq 0 ]
  [[ "$output" == *"Student access:"*"access cards"* ]]
}
