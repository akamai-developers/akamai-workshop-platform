#!/usr/bin/env bash
set -euo pipefail

POCKETBASE_BIN="${POCKETBASE_BIN:-pocketbase}"
PORT="${PORT:-18091}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
DATA_DIR="${TEST_ROOT}/pb_data"
CONFIG_DIR="${TEST_ROOT}/config"
LOG="${TEST_ROOT}/pocketbase.log"
PID=""

cleanup() {
    local status="$1"
    if [[ "${status}" -ne 0 && -f "${LOG}" ]]; then
        tail -50 "${LOG}" >&2
    fi
    if [[ -n "${PID}" ]] && kill -0 "${PID}" 2>/dev/null; then
        kill "${PID}"
        wait "${PID}" 2>/dev/null || true
    fi
    rm -rf "${TEST_ROOT}"
}
trap 'cleanup $?' EXIT

command -v "${POCKETBASE_BIN}" >/dev/null 2>&1 \
    || { echo "ERROR: set POCKETBASE_BIN to a PocketBase 0.40.4 executable" >&2; exit 2; }
mkdir -p "${DATA_DIR}" "${CONFIG_DIR}"
"${POCKETBASE_BIN}" superuser create admin@example.test test-admin-password-123 \
    --dir="${DATA_DIR}" >/dev/null

write_inventory() {
    local first_password="$1"
    local second_password="$2"
    printf '%s' "[{\"student_number\":\"s01\",\"workspace_url\":\"https://s01.example.test/\",\"workspace_password\":\"${first_password}\"},{\"student_number\":\"s02\",\"workspace_url\":\"https://s02.example.test/\",\"workspace_password\":\"${second_password}\"}]" \
        > "${CONFIG_DIR}/slots.json"
}

start_server() {
    WORKSHOP_SLOTS_FILE="${CONFIG_DIR}/slots.json" "${POCKETBASE_BIN}" serve \
        --http="127.0.0.1:${PORT}" \
        --dir="${DATA_DIR}" \
        --hooksDir="${ROOT}/infra/student-access/pb_hooks" \
        --publicDir="${ROOT}/infra/student-access/pb_public" \
        --migrationsDir="${ROOT}/infra/student-access/pb_migrations" \
        --automigrate=false >"${LOG}" 2>&1 &
    PID=$!
    for _ in $(seq 1 50); do
        if curl -fsS "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.1
    done
    cat "${LOG}" >&2
    return 1
}

stop_server() {
    kill "${PID}"
    wait "${PID}" 2>/dev/null || true
    PID=""
}

register() {
    curl -fsS -X POST "http://127.0.0.1:${PORT}/api/workshop/register" \
        -H 'Content-Type: application/json' \
        -d "$1"
}

admin_token() {
    curl -fsS -X POST "http://127.0.0.1:${PORT}/api/collections/_superusers/auth-with-password" \
        -H 'Content-Type: application/json' \
        -d '{"identity":"admin@example.test","password":"test-admin-password-123"}' \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])'
}

write_inventory "pw-one" "pw-two"
start_server

curl -fsS "http://127.0.0.1:${PORT}/" | grep -q 'Claim your'
curl -fsS "http://127.0.0.1:${PORT}/present.html" | grep -q '/qrcode.min.js'
curl -fsS "http://127.0.0.1:${PORT}/qrcode.min.js" >/dev/null

invalid_status="$(curl -sS -o "${TEST_ROOT}/invalid.json" -w '%{http_code}' -X POST \
    "http://127.0.0.1:${PORT}/api/workshop/register" \
    -H 'Content-Type: application/json' \
    -d '{"name":"","email":"not-an-email"}')"
[[ "${invalid_status}" == "400" ]]
grep -q 'INVALID_INPUT' "${TEST_ROOT}/invalid.json"

# This passes the form's basic @/dot check but is rejected by PocketBase's
# email field. It must still be reported as invalid input, not an outage.
invalid_pb_status="$(curl -sS -o "${TEST_ROOT}/invalid-pb.json" -w '%{http_code}' -X POST \
    "http://127.0.0.1:${PORT}/api/workshop/register" \
    -H 'Content-Type: application/json' \
    -d '{"name":"Bad Email","email":"ada..lovelace@example.com"}')"
[[ "${invalid_pb_status}" == "400" ]]
grep -q 'INVALID_INPUT' "${TEST_ROOT}/invalid-pb.json"

register '{"name":"Ada Lovelace","email":" ADA@Example.com "}' > "${TEST_ROOT}/ada.json" &
ada_pid=$!
register '{"name":"Grace Hopper","email":"grace@example.com"}' > "${TEST_ROOT}/grace.json" &
grace_pid=$!
wait "${ada_pid}"
wait "${grace_pid}"
python3 - "${TEST_ROOT}/ada.json" "${TEST_ROOT}/grace.json" <<'PY'
import json, sys
records = [json.load(open(path)) for path in sys.argv[1:]]
assert {record["student_number"] for record in records} == {"s01", "s02"}
assert all(record["returning"] is False for record in records)
PY

again="$(register '{"name":"Ignored Name","email":"ada@example.com"}')"
python3 -c 'import json,sys; r=json.loads(sys.argv[1]); assert r["student_number"] in ("s01","s02") and r["returning"] is True' "${again}"

# An instructor edit can change email casing; the same student must still get
# their original slot, not be treated as a new claimant.
TOKEN="$(admin_token)"
ADA_ID="$(curl -fsS "http://127.0.0.1:${PORT}/api/collections/registrations/records" \
    -H "Authorization: ${TOKEN}" \
    | python3 -c 'import json,sys; print(next(r["id"] for r in json.load(sys.stdin)["items"] if r["email"]=="ada@example.com"))')"
curl -fsS -X PATCH "http://127.0.0.1:${PORT}/api/collections/registrations/records/${ADA_ID}" \
    -H "Authorization: ${TOKEN}" -H 'Content-Type: application/json' \
    -d '{"email":"ADA@Example.com"}' >/dev/null
mixed_case="$(register '{"name":"Ada Lovelace","email":"ada@example.com"}')"
python3 -c 'import json,sys; r=json.loads(sys.argv[1]); assert r["returning"] is True' "${mixed_case}"

# A reset must reserve the slot and suppress its credential even for the same email.
curl -fsS -X PATCH "http://127.0.0.1:${PORT}/api/collections/registrations/records/${ADA_ID}" \
    -H "Authorization: ${TOKEN}" -H 'Content-Type: application/json' \
    -d '{"resetting":true}' >/dev/null
reset_status="$(curl -sS -o "${TEST_ROOT}/reset.json" -w '%{http_code}' -X POST \
    "http://127.0.0.1:${PORT}/api/workshop/register" -H 'Content-Type: application/json' \
    -d '{"name":"Ada Lovelace","email":"ada@example.com"}')"
[[ "${reset_status}" == "409" ]]
grep -q 'WORKSPACE_RESETTING' "${TEST_ROOT}/reset.json"
curl -fsS -X PATCH "http://127.0.0.1:${PORT}/api/collections/registrations/records/${ADA_ID}" \
    -H "Authorization: ${TOKEN}" -H 'Content-Type: application/json' \
    -d '{"resetting":false}' >/dev/null

status="$(curl -sS -o "${TEST_ROOT}/full.json" -w '%{http_code}' -X POST \
    "http://127.0.0.1:${PORT}/api/workshop/register" \
    -H 'Content-Type: application/json' \
    -d '{"name":"Full Workshop","email":"full@example.com"}')"
[[ "${status}" == "409" ]]
grep -q 'WORKSHOP_FULL' "${TEST_ROOT}/full.json"

generic_status="$(curl -sS -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:${PORT}/api/collections/registrations/records")"
[[ "${generic_status}" != "200" ]]

write_inventory "rotated-one" "rotated-two"
rotated="$(register '{"name":"Ada Lovelace","email":"ada@example.com"}')"
python3 -c 'import json,sys; r=json.loads(sys.argv[1]); expected={"s01":"rotated-one","s02":"rotated-two"}; assert r["workspace_password"]==expected[r["student_number"]]' "${rotated}"

stop_server
start_server
persisted="$(register '{"name":"Ada Lovelace","email":"ada@example.com"}')"
python3 -c 'import json,sys; r=json.loads(sys.argv[1]); assert r["student_number"] in ("s01","s02") and r["returning"] is True' "${persisted}"

echo "student access integration checks passed"
