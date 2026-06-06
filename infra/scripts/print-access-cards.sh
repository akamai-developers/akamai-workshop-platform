#!/usr/bin/env bash
set -euo pipefail

# Generate printable HTML access cards from access-cards.csv.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
CSV="${INFRA_DIR}/manifests/generated/access-cards.csv"
HTML="${INFRA_DIR}/manifests/generated/access-cards.html"

if [ ! -f "${CSV}" ]; then
    echo "No access-cards.csv found. Run generate-pods.sh first."
    exit 1
fi

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
  </div>
EOF
done

cat >> "${HTML}" << 'FOOTER'
</div>
</body>
</html>
FOOTER

echo "Generated: ${HTML}"
echo "Open in a browser and print (Ctrl+P / Cmd+P)"
