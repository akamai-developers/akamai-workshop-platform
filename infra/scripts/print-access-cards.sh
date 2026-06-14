#!/usr/bin/env bash
set -euo pipefail

# Generate printable HTML access cards from access-cards.csv.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
CSV="${INFRA_DIR}/manifests/generated/access-cards.csv"
HTML="${INFRA_DIR}/manifests/generated/access-cards.html"
HELM_VALUES="${INFRA_DIR}/manifests/helm-values.yaml"

if [ ! -f "${CSV}" ]; then
    echo "No access-cards.csv found. Run generate-pods.sh first."
    exit 1
fi

# Composition: auto-detected from the generated helm-values.yaml (env/flags override).
# Only used to add a NON-SECRET "pre-wired" note when cluster_access=scoped or
# object_storage=managed. Default (none/none) leaves the card byte-identical to before.
_detect() { grep -E "^$1:" "$HELM_VALUES" 2>/dev/null | head -1 | awk '{print $2}' || true; }
NAMESPACE="${NAMESPACE:-$(_detect namespace)}";          NAMESPACE="${NAMESPACE:-workshop}"
CLUSTER_ACCESS="${CLUSTER_ACCESS:-$(_detect cluster_access)}"; CLUSTER_ACCESS="${CLUSTER_ACCESS:-none}"
OBJECT_STORAGE="${OBJECT_STORAGE:-$(_detect object_storage)}"; OBJECT_STORAGE="${OBJECT_STORAGE:-none}"
for arg in "$@"; do
    case "$arg" in
        --cluster-access=*) CLUSTER_ACCESS="${arg#*=}" ;;
        --object-storage=*) OBJECT_STORAGE="${arg#*=}" ;;
        --namespace=*)      NAMESPACE="${arg#*=}" ;;
    esac
done

cat > "${HTML}" << 'HEADER'
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>AI Agents Workshop — Access Cards</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 0; padding: 20px; }
  .grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 16px; }
  .card {
    border: 2px solid #333;
    border-radius: 8px;
    padding: 16px;
    text-align: center;
    page-break-inside: avoid;
  }
  .card h2 { margin: 0 0 8px; font-size: 24px; }
  .card .url { font-size: 12px; color: #666; word-break: break-all; margin: 8px 0; }
  .card .password { font-family: monospace; font-size: 18px; font-weight: bold; color: #c00; margin: 8px 0; }
  .card .label { font-size: 11px; color: #999; text-transform: uppercase; }
  .card .extra { font-family: monospace; font-size: 11px; color: #333; margin: 4px 0; word-break: break-all; }
  .title { text-align: center; margin-bottom: 24px; }
  @media print {
    .grid { grid-template-columns: repeat(4, 1fr); }
    .card { border: 1px solid #000; }
  }
</style>
</head>
<body>
<div class="title">
  <h1>Akamai Workshop Platform</h1>
  <p>Your browser IDE + GPU inference</p>
</div>
<div class="grid">
HEADER

# Skip header line and generate cards
tail -n +2 "${CSV}" | while IFS=, read -r num url password; do
    cat >> "${HTML}" << EOF
  <div class="card">
    <h2>Station ${num}</h2>
    <div class="label">URL</div>
    <div class="url">${url}</div>
    <div class="label">Password</div>
    <div class="password">${password}</div>
EOF
    # Non-secret pre-wired note (no key/kubeconfig material — just the namespace).
    if [ "${CLUSTER_ACCESS}" = "scoped" ] || [ "${OBJECT_STORAGE}" = "managed" ]; then
        _wired=""
        [ "${CLUSTER_ACCESS}" = "scoped" ] && _wired="kubeconfig"
        [ "${OBJECT_STORAGE}" = "managed" ] && _wired="${_wired:+${_wired} + }bucket"
        cat >> "${HTML}" << EOF
    <div class="label">Pre-wired</div>
    <div class="extra">ns ${NAMESPACE}-${num} · ${_wired} ready</div>
EOF
    fi
    echo "  </div>" >> "${HTML}"
done

cat >> "${HTML}" << 'FOOTER'
</div>
</body>
</html>
FOOTER

echo "Generated: ${HTML}"
echo "Open in a browser and print (Ctrl+P / Cmd+P)"
