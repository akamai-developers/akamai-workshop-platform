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

CONTENT_REPO="${CONTENT_REPO:-}"
[ -z "${CONTENT_REPO}" ] && CONTENT_REPO="https://github.com/akamai-developers/ai-agents-workshop.git"
CONTENT_REF="${CONTENT_REF:-main}"
WORKSPACE_DIR="${WORKSPACE_DIR:-${HOME:-/home/coder}/workshop}"
BIND_ADDR="${BIND_ADDR:-0.0.0.0:8080}"

log() { echo "[startup] $*"; }

# --- 1. Clone the content repo (idempotent across pod restarts) ---------------
if command -v git >/dev/null 2>&1; then
  if [ -e "${WORKSPACE_DIR}/.git" ]; then
    log "content already present at ${WORKSPACE_DIR}; skipping clone"
  else
    log "cloning ${CONTENT_REPO}#${CONTENT_REF} → ${WORKSPACE_DIR}"
    mkdir -p "${WORKSPACE_DIR}"
    if ! ( cd "${WORKSPACE_DIR}" \
        && git init -q \
        && git remote add origin "${CONTENT_REPO}" \
        && git fetch --depth=1 origin "${CONTENT_REF}" \
        && git checkout -q FETCH_HEAD ); then
      log "WARN: clone failed; starting code-server with an empty workspace"
    fi
  fi
else
  log "WARN: git not found; cannot clone content; starting code-server anyway"
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
exec code-server --bind-addr "${BIND_ADDR}" --auth password "${WORKSPACE_DIR}"
