#!/usr/bin/env bash
# Image-agnostic workspace startup for akamai-workshop-platform.
#
# Works in BOTH modes:
#   1. ENTRYPOINT of the dedicated prebuilt image (code-server + python3 + git baked in).
#   2. A `command:` override on the stock `codercom/code-server` image, with this file
#      mounted from the `workspace-startup` ConfigMap (the no-Docker path used by the
#      e2e smoke test). In that mode python3 is installed at startup via uv.
#
# It clones the workshop content at pod startup (no content is baked into the image),
# installs Python and its deps into a .venv, configures auto-activation for new
# terminals, then starts code-server. PASSWORD, VLLM_HOST, and MODEL_NAME come from
# the pod env; code-server reads $PASSWORD itself.
set -uo pipefail

CONTENT_REPO_RAW="${CONTENT_REPO:-}"
CONTENT_REF="${CONTENT_REF:-main}"
WORKSPACE_DIR="${WORKSPACE_DIR:-${HOME:-/home/coder}/workshop}"
BIND_ADDR="${BIND_ADDR:-0.0.0.0:8080}"

DEFAULT_ORG="akamai-developers"
DEFAULT_REPO="ai-agents-workshop"

log() { echo "[startup] $*"; }

# Coerce whatever CONTENT_REPO shape we were handed into a clonable git URL.
# Accepts: "" (→ the default workshop), a full URL (https/ssh/scp — used as-is), an
# "owner/repo" shorthand, or a bare repo name (→ the default org). Without this, the
# deploy wizard's old bare-name default ("ai-agents-workshop") was fed straight to
# `git remote add`, which is not a URL, so every workspace started empty.
normalize_repo() {
  local r="${1:-}"
  r="${r%/}"                                                  # drop a trailing slash
  if [ -z "${r}" ]; then
    printf 'https://github.com/%s/%s.git' "${DEFAULT_ORG}" "${DEFAULT_REPO}"
  elif printf '%s' "${r}" | grep -qE '://|^git@'; then
    printf '%s' "${r}"                                         # already a full URL
  elif printf '%s' "${r}" | grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
    printf 'https://github.com/%s.git' "${r%.git}"            # owner/repo shorthand
  else
    printf 'https://github.com/%s/%s.git' "${DEFAULT_ORG}" "${r%.git}"  # bare name → default org
  fi
}

CONTENT_REPO="$(normalize_repo "${CONTENT_REPO_RAW}")"

# --- 1. Clone the content repo (idempotent + atomic across pod restarts) -------
# "Present" means a *resolvable HEAD*, not merely a .git directory: a failed
# `git init`+fetch leaves a bare .git behind, and keying off that would wedge the
# workspace empty forever. We clone into a temp dir and only swap it into place on
# full success, so a failed clone leaves nothing and the next pod start retries.
content_present() { git -C "${WORKSPACE_DIR}" rev-parse --verify HEAD >/dev/null 2>&1; }

clone_content() {
  local tmp="${WORKSPACE_DIR}.cloning"
  rm -rf "${tmp}"
  mkdir -p "${tmp}"
  if ( cd "${tmp}" \
        && git init -q \
        && git remote add origin "${CONTENT_REPO}" \
        && git fetch --depth=1 origin "${CONTENT_REF}" \
        && git checkout -q FETCH_HEAD ); then
    if [ -d "${WORKSPACE_DIR}" ]; then
      rm -rf "${WORKSPACE_DIR}/.git"                          # clear any stale/partial .git first
      shopt -s dotglob
      mv "${tmp}"/* "${WORKSPACE_DIR}"/ 2>/dev/null || true   # merge into an existing dir
      shopt -u dotglob
      rm -rf "${tmp}"
    else
      mv "${tmp}" "${WORKSPACE_DIR}"                          # atomic rename (fresh pod)
    fi
    return 0
  fi
  rm -rf "${tmp}"                                             # leave no partial .git behind
  return 1
}

if command -v git >/dev/null 2>&1; then
  if content_present; then
    log "content already present at ${WORKSPACE_DIR}; skipping clone"
  else
    log "cloning ${CONTENT_REPO}#${CONTENT_REF} → ${WORKSPACE_DIR}"
    if clone_content; then
      log "content cloned into ${WORKSPACE_DIR}"
    else
      log "WARN: clone of ${CONTENT_REPO}#${CONTENT_REF} failed; starting code-server with an empty workspace"
      mkdir -p "${WORKSPACE_DIR}"
      cat > "${WORKSPACE_DIR}/WORKSHOP-NOT-LOADED.md" << EOF
# Workshop content did not load

The platform tried to clone the workshop content but the clone failed, so this
workspace is empty.

- Repo tried:  ${CONTENT_REPO}
- Ref:         ${CONTENT_REF}

Likely causes: the repo is private (no credentials are injected into workspaces),
the owner/URL is wrong, or the ref does not exist. Fix \`content_repo\` and recreate
the workspace pods. See infra/docs/troubleshooting.md.
EOF
    fi
  fi
else
  log "WARN: git not found in this image; cannot clone content; starting code-server anyway"
  mkdir -p "${WORKSPACE_DIR}"
fi

# --- 2. Install Python if missing (via uv, no root needed) -------------------
if ! command -v python3 >/dev/null 2>&1; then
  log "python3 not found; installing via uv (no root needed)"
  if curl -LsSf https://astral.sh/uv/install.sh | sh 2>/dev/null; then
    export PATH="${HOME}/.local/bin:${PATH}"
    log "uv installed"
  else
    log "WARN: failed to install uv; Python will not be available"
  fi
fi

# --- 3. Create .venv and install Python deps ----------------------------------
REQ="${WORKSPACE_DIR}/requirements.txt"
if [ -f "${REQ}" ]; then
  if command -v uv >/dev/null 2>&1; then
    log "creating .venv with Python 3.12 and installing deps (via uv)"
    if uv venv "${WORKSPACE_DIR}/.venv" --python 3.12 --seed 2>&1; then
      uv pip install --python "${WORKSPACE_DIR}/.venv/bin/python" --no-cache -r "${REQ}" \
        && log "deps installed into .venv" \
        || log "WARN: pip install into .venv failed; continuing"
    else
      log "WARN: uv venv creation failed; continuing without Python"
    fi
  elif command -v python3 >/dev/null 2>&1; then
    log "installing Python deps from requirements.txt"
    if python3 -m venv "${WORKSPACE_DIR}/.venv" >/dev/null 2>&1; then
      "${WORKSPACE_DIR}/.venv/bin/pip" install --no-cache-dir -r "${REQ}" \
        && log "deps installed into .venv" \
        || log "WARN: pip install into .venv failed; continuing"
    else
      python3 -m pip install --no-cache-dir --user -r "${REQ}" >/dev/null 2>&1 \
        && log "deps installed (--user)" \
        || log "WARN: pip install failed/unavailable; continuing"
    fi
  else
    log "WARN: requirements.txt present but neither uv nor python3 available; skipping deps"
  fi
else
  log "no requirements.txt; skipping Python deps"
fi

# --- 4. Auto-activate .venv in new terminals ----------------------------------
BASHRC="${HOME}/.bashrc"
MARKER="# akamai-workshop-venv"
if ! grep -q "${MARKER}" "${BASHRC}" 2>/dev/null; then
  cat >> "${BASHRC}" << 'VENV'
# akamai-workshop-venv
[ -d "$HOME/.local/bin" ] && export PATH="$HOME/.local/bin:$PATH"
[ -f "$HOME/workshop/.venv/bin/activate" ] && source "$HOME/workshop/.venv/bin/activate"
VENV
  log ".venv auto-activation added to .bashrc"
fi

# --- 5. Start code-server ----------------------------------------------------
log "starting code-server on ${BIND_ADDR} (workspace: ${WORKSPACE_DIR})"
if [ -n "${VLLM_HOST:-}" ]; then log "VLLM_HOST=${VLLM_HOST}"; fi
if [ -n "${MODEL_NAME:-}" ]; then log "MODEL_NAME=${MODEL_NAME}"; fi
if [ -n "${MODEL_NAMES:-}" ]; then log "MODEL_NAMES=${MODEL_NAMES}"; fi
exec code-server --bind-addr "${BIND_ADDR}" --auth password "${WORKSPACE_DIR}"
