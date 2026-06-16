#!/usr/bin/env bash
# Shared bats helpers. `load helper` from any *.bats file in tests/bats/.

# Repo root (tests/bats/ -> tests/ -> root).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FAKES_DIR="${REPO_ROOT}/tests/fakes"

# Prepend the fakes to PATH so `linode-cli`/`curl` resolve to the shims.
use_fakes() {
  export PATH="${FAKES_DIR}:${PATH}"
  export FAKE_LINODE_LOG="${BATS_TEST_TMPDIR}/linode.log"
  export FAKE_CURL_LOG="${BATS_TEST_TMPDIR}/curl.log"
  : > "${FAKE_LINODE_LOG}"
  : > "${FAKE_CURL_LOG}"
}

# Assert that the fake linode-cli log contains a line matching a regex.
assert_linode_called() {
  grep -qE "$1" "${FAKE_LINODE_LOG}" \
    || { echo "expected linode-cli call matching: $1"; echo "--- log ---"; cat "${FAKE_LINODE_LOG}"; return 1; }
}
