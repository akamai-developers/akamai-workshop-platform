#!/usr/bin/env bash
set -euo pipefail

# OPTIONAL / ADVANCED. Build + push the generic workspace image.
#
# You do NOT need this for a normal deploy: the platform runs the stock
# codercom/code-server image with startup.sh mounted from a ConfigMap (no Docker,
# no registry). Build a dedicated image only if you want faster pod start (python3 +
# git + the Python extension pre-baked instead of installed at startup).
#
# The image bakes NO workshop content — startup.sh clones $CONTENT_REPO at pod start,
# so one image serves any workshop. Once pushed, point the platform at it via the
# wizard's image input (or generate-pods.sh --image / helm value workspace_image).
#
# Requires: Docker, and a registry login, e.g.
#   echo "$CR_PAT" | docker login ghcr.io -u <user> --password-stdin

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
CONTEXT="${INFRA_DIR}/images/workspace"

REGISTRY="${REGISTRY:-ghcr.io/akamai-developers}"
TAG="${TAG:-latest}"

# VARIANT selects the editor image: code-server (default) or jupyter. The jupyter
# variant bakes jupyterlab + kubectl (Dockerfile.jupyter) and gets its own image name.
VARIANT="${VARIANT:-code-server}"
case "$VARIANT" in
    jupyter)
        DOCKERFILE="${CONTEXT}/Dockerfile.jupyter"
        IMAGE="${IMAGE:-ai-agents-workspace-jupyter}"
        ;;
    code-server)
        DOCKERFILE="${CONTEXT}/Dockerfile"
        IMAGE="${IMAGE:-ai-agents-workspace}"
        ;;
    *) echo "ERROR: VARIANT must be 'code-server' or 'jupyter' (got '$VARIANT')" >&2; exit 1 ;;
esac

FULL_TAG="${REGISTRY}/${IMAGE}:${TAG}"

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker not found. This optional path needs Docker + a registry login." >&2
    echo "       For a no-Docker deploy, use the stock image (the default)." >&2
    exit 1
fi

echo "=== Building ${FULL_TAG} (content-free; cloned at pod startup) ==="
echo ""

docker build \
    --tag "${FULL_TAG}" \
    --file "${DOCKERFILE}" \
    --platform linux/amd64 \
    "${CONTEXT}"

echo ""
echo "=== Pushing ${FULL_TAG} ==="
docker push "${FULL_TAG}"

echo ""
echo "=== Done. ==="
echo "Image: ${FULL_TAG}"
echo "Use it:  ./deploy.sh ... (set the workspace image)  OR"
echo "         ./scripts/generate-pods.sh --image ${FULL_TAG} ..."
echo ""
echo "If pushing to ghcr.io, set the package to PUBLIC so the cluster can pull"
echo "without auth, or configure an imagePullSecret in the namespace."
