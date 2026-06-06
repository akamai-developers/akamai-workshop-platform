#!/usr/bin/env bash
set -euo pipefail

# Issue (or renew) a wildcard Let's Encrypt cert for *.<subdomain>.<domain>
# using lego + Linode DNS-01, and store it as a TLS Secret in the workshop ns.
#
# Idempotent: lego 5.x's `run` command issues a new cert OR renews an existing
# one found at --path. When a cert is already on disk we pass --renew-days=30 so
# it only renews inside the 30-day window; otherwise the run is a no-op. (lego
# 5.x removed the separate `renew` command and renamed --days to --renew-days.)
#
# Requires:
#   - lego installed locally:  brew install lego  /  apt install lego
#   - LINODE_TOKEN with Domains: Read/Write scope, OR TF_VAR_token, OR
#     a token line in terraform/terraform.tfvars
#   - kubeconfig.yaml in infra/ (created by provision.sh)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
KUBECONFIG_PATH="${INFRA_DIR}/kubeconfig.yaml"
CERT_DIR="${INFRA_DIR}/.certs"

DOMAIN="${DOMAIN:-}"
SUBDOMAIN_PREFIX="${SUBDOMAIN_PREFIX:-workshop}"
EMAIL="${EMAIL:-admin@${DOMAIN}}"
SECRET_NAME="${SECRET_NAME:-workshop-tls}"
NAMESPACE="${NAMESPACE:-workshop}"

WILDCARD="*.${SUBDOMAIN_PREFIX}.${DOMAIN}"
APEX="${SUBDOMAIN_PREFIX}.${DOMAIN}"

# ===========================================================================
# No-domain mode (DOMAIN empty): self-signed wildcard for *.<base_host>.
# No lego, no Linode DNS, no token scope needed. Early-exit before the LE path.
# ===========================================================================
if [ -z "${DOMAIN}" ]; then
    BASE_HOST="${BASE_HOST:-}"
    if [ -z "${BASE_HOST}" ] && command -v terraform >/dev/null 2>&1 \
        && [ -d "${INFRA_DIR}/terraform/.terraform" ]; then
        BASE_HOST="$(cd "${INFRA_DIR}/terraform" && terraform output -raw base_host 2>/dev/null || true)"
    fi
    if [ -z "${BASE_HOST}" ]; then
        echo "ERROR: no-domain mode needs BASE_HOST (e.g. 192-0-2-10.sslip.io)." >&2
        echo "       Set BASE_HOST=… or run after provision.sh (terraform output base_host)." >&2
        exit 1
    fi
    command -v openssl >/dev/null 2>&1 || { echo "ERROR: openssl not found." >&2; exit 1; }
    command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found." >&2; exit 1; }

    echo "=== Self-signed wildcard TLS cert (no-domain mode) ==="
    echo "    Host:    *.${BASE_HOST}"
    echo "    Secret:  ${NAMESPACE}/${SECRET_NAME}"
    echo ""

    mkdir -p "${CERT_DIR}/selfsigned"
    SS_KEY="${CERT_DIR}/selfsigned/tls.key"
    SS_CRT="${CERT_DIR}/selfsigned/tls.crt"

    # SAN must include the wildcard AND the bare base host. 365-day self-signed.
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "${SS_KEY}" -out "${SS_CRT}" -days 365 \
        -subj "/CN=*.${BASE_HOST}" \
        -addext "subjectAltName=DNS:*.${BASE_HOST},DNS:${BASE_HOST}"

    [ -f "${KUBECONFIG_PATH}" ] && export KUBECONFIG="${KUBECONFIG_PATH}"
    kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || kubectl create ns "${NAMESPACE}"
    kubectl -n "${NAMESPACE}" create secret tls "${SECRET_NAME}" \
        --cert="${SS_CRT}" --key="${SS_KEY}" \
        --dry-run=client -o yaml | kubectl apply -f -

    echo ""
    echo "=== Done (self-signed) ==="
    echo "Students accept the browser warning once; then code-server + WebSockets work."
    echo "Want a trusted cert? Re-run with a domain set (Linode DNS + Let's Encrypt)."
    exit 0
fi

# ---------------------------------------------------------------------------
# 1. Token discovery
# ---------------------------------------------------------------------------
if [ -z "${LINODE_TOKEN:-}" ] && [ -n "${TF_VAR_token:-}" ]; then
    LINODE_TOKEN="${TF_VAR_token}"
fi

if [ -z "${LINODE_TOKEN:-}" ] && [ -f "${INFRA_DIR}/terraform/terraform.tfvars" ]; then
    LINODE_TOKEN=$(grep -E '^\s*token\s*=' "${INFRA_DIR}/terraform/terraform.tfvars" \
        | sed -E 's/.*=\s*"([^"]+)".*/\1/')
fi

if [ -z "${LINODE_TOKEN:-}" ]; then
    echo "ERROR: set LINODE_TOKEN, TF_VAR_token, or put it in terraform/terraform.tfvars" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Token validation — profile reachable, AND Domains scope granted
#
#    The cheap /v4/profile check only proves the token isn't expired. To
#    actually reach lego's code path we need to confirm Domains: Read/Write,
#    which only shows up when you hit /v4/domains.
# ---------------------------------------------------------------------------
if ! curl -sf -H "Authorization: Bearer ${LINODE_TOKEN}" \
        https://api.linode.com/v4/profile >/dev/null; then
    echo "ERROR: Linode API rejected the token (401)." >&2
    echo "  - is it expired?" >&2
    echo "  - does it match TF_VAR_token / terraform.tfvars?" >&2
    exit 1
fi

DOMAINS_JSON="$(mktemp -t linode-domains.XXXXXX.json)"
trap 'rm -f "${DOMAINS_JSON}"' EXIT

DOMAINS_HTTP=$(curl -s -o "${DOMAINS_JSON}" -w "%{http_code}" \
    -H "Authorization: Bearer ${LINODE_TOKEN}" \
    "https://api.linode.com/v4/domains?page_size=500")

if [ "${DOMAINS_HTTP}" != "200" ]; then
    echo "ERROR: token cannot list Linode Domains (HTTP ${DOMAINS_HTTP})." >&2
    echo "  This almost always means the token is missing 'Domains: Read/Write'." >&2
    echo "" >&2
    echo "  Recreate the token at https://cloud.linode.com/profile/tokens with:" >&2
    echo "    Domains: Read/Write   (required for DNS-01 challenge)" >&2
    echo "    Kubernetes: Read/Write" >&2
    echo "    Linodes: Read/Write" >&2
    echo "    NodeBalancers: Read/Write" >&2
    echo "    Volumes: Read/Write" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 3. Zone discovery — confirm a parent zone for ${APEX} exists in Linode DNS,
#    and detect the foot-gun where ${APEX} has been added as a SEPARATE zone
#    alongside ${DOMAIN} (shadows the parent's wildcard A record).
# ---------------------------------------------------------------------------
DOMAIN_LIST=$(python3 -c "
import json,sys
data=json.load(open('${DOMAINS_JSON}'))
for d in data.get('data', []):
    print(d['domain'])
")

HAS_APEX_ZONE=0
HAS_SUB_ZONE=0
if printf '%s\n' "${DOMAIN_LIST}" | grep -qx "${DOMAIN}"; then HAS_APEX_ZONE=1; fi
if printf '%s\n' "${DOMAIN_LIST}" | grep -qx "${APEX}";   then HAS_SUB_ZONE=1;  fi

if [ "${HAS_APEX_ZONE}" -eq 0 ] && [ "${HAS_SUB_ZONE}" -eq 0 ]; then
    echo "ERROR: neither '${DOMAIN}' nor '${APEX}' exists as a Linode DNS zone" >&2
    echo "       for the token you're using." >&2
    echo "" >&2
    echo "  Create the zone at https://cloud.linode.com/domains/create" >&2
    echo "  (use '${DOMAIN}' — that's what Terraform expects)." >&2
    echo "" >&2
    echo "  Zones visible to this token:" >&2
    if [ -z "${DOMAIN_LIST}" ]; then
        echo "    (none)" >&2
    else
        printf '%s\n' "${DOMAIN_LIST}" | sed 's/^/    /' >&2
    fi
    exit 1
fi

if [ "${HAS_APEX_ZONE}" -eq 1 ] && [ "${HAS_SUB_ZONE}" -eq 1 ]; then
    cat >&2 <<EOF

WARNING: '${DOMAIN}' AND '${APEX}' both exist as separate zones in Linode DNS.

  Cert issuance will still work — lego writes _acme-challenge into whichever
  zone is the closest match (it'll use '${APEX}').

  BUT: having '${APEX}' as its own zone SHADOWS the wildcard A record that
  Terraform creates in '${DOMAIN}'. Any query for ${WILDCARD} hits the empty
  '${APEX}' zone and gets NXDOMAIN, so workshop URLs (s01.${APEX}, ...) will
  not resolve until you fix this.

  Recommended: delete the '${APEX}' zone from
  https://cloud.linode.com/domains  — Terraform manages the records inside
  '${DOMAIN}', and you don't need a separate zone for the subdomain.

  Continuing in 5s...

EOF
    sleep 5
fi

# ---------------------------------------------------------------------------
# 4. Local tool checks
# ---------------------------------------------------------------------------
if ! command -v lego >/dev/null 2>&1; then
    echo "ERROR: lego not found. Install with: brew install lego  (or apt install lego)" >&2
    exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
    echo "ERROR: kubectl not found. Install kubectl first." >&2
    exit 1
fi

if [ ! -s "${KUBECONFIG_PATH}" ]; then
    echo "ERROR: kubeconfig at ${KUBECONFIG_PATH} is missing or empty." >&2
    echo "       Run ./scripts/provision.sh first to create it." >&2
    exit 1
fi

# Reject obviously-stub kubeconfigs (no clusters block).
if ! grep -q '^clusters:' "${KUBECONFIG_PATH}"; then
    echo "ERROR: kubeconfig at ${KUBECONFIG_PATH} has no 'clusters:' block." >&2
    echo "       It looks like a placeholder. Re-run ./scripts/provision.sh." >&2
    exit 1
fi

export KUBECONFIG="${KUBECONFIG_PATH}"
export LINODE_TOKEN

# Linode publishes new DNS records to its NS fleet (ns1-5.linode.com) only on
# its ~15-min zone-update cycle, so the lego Linode plugin's default 2-min
# propagation poll can time out before all 5 NS see the record (varies by
# region/anycast endpoint). Give it up to 20 min — lego exits as soon as all
# NS have the record, so this is just an upper bound, not a fixed wait.
export LINODE_PROPAGATION_TIMEOUT="${LINODE_PROPAGATION_TIMEOUT:-1200}"

if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "ERROR: kubectl cannot reach the cluster with KUBECONFIG=${KUBECONFIG_PATH}." >&2
    echo "       Re-run ./scripts/provision.sh or check the file is current." >&2
    exit 1
fi

mkdir -p "${CERT_DIR}"

CERT_FILE="${CERT_DIR}/certificates/_.${SUBDOMAIN_PREFIX}.${DOMAIN}.crt"
KEY_FILE="${CERT_DIR}/certificates/_.${SUBDOMAIN_PREFIX}.${DOMAIN}.key"

# ---------------------------------------------------------------------------
# 5. Issue or renew
# ---------------------------------------------------------------------------
echo "=== Wildcard TLS cert ==="
echo "    Domain:  ${WILDCARD}"
echo "    Email:   ${EMAIL}"
echo "    Output:  ${CERT_DIR}/certificates/"
if [ "${HAS_SUB_ZONE}" -eq 1 ]; then
    echo "    Zone:    ${APEX}  (lego writes _acme-challenge into this zone)"
else
    echo "    Zone:    ${DOMAIN}  (lego writes _acme-challenge.${SUBDOMAIN_PREFIX} into this zone)"
fi
echo ""

LEGO_COMMON=(
    --accept-tos
    --email="${EMAIL}"
    --dns=linode
    --dns.propagation.disable-rns
    --domains="${WILDCARD}"
    --path="${CERT_DIR}"
)

if [ -f "${CERT_FILE}" ] && [ -f "${KEY_FILE}" ]; then
    echo "Cert already on disk — running 'lego run --renew-days=30'."
    echo "(Renews only if within 30 days of expiry. Otherwise no-op.)"
    echo ""
    lego run "${LEGO_COMMON[@]}" --renew-days=30
else
    echo "No cert on disk — running 'lego run'."
    echo ""
    lego run "${LEGO_COMMON[@]}"
fi

if [ ! -f "${CERT_FILE}" ] || [ ! -f "${KEY_FILE}" ]; then
    echo "" >&2
    echo "ERROR: lego completed but cert/key are not at the expected paths:" >&2
    echo "       ${CERT_FILE}" >&2
    echo "       ${KEY_FILE}" >&2
    echo "" >&2
    echo "Contents of ${CERT_DIR}/certificates/ :" >&2
    ls -la "${CERT_DIR}/certificates/" 2>&1 | sed 's/^/  /' >&2 || true
    exit 1
fi

# ---------------------------------------------------------------------------
# 6. Store as Kubernetes TLS Secret
# ---------------------------------------------------------------------------
echo ""
echo "=== Storing as Secret ${NAMESPACE}/${SECRET_NAME} ==="

kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || kubectl create ns "${NAMESPACE}"

kubectl -n "${NAMESPACE}" create secret tls "${SECRET_NAME}" \
    --cert="${CERT_FILE}" \
    --key="${KEY_FILE}" \
    --dry-run=client -o yaml | kubectl apply -f -

# Sanity check.
kubectl -n "${NAMESPACE}" get secret "${SECRET_NAME}" \
    -o jsonpath='{.metadata.name}{"\t"}{.type}{"\n"}'

echo ""
echo "=== Done ==="
echo "Cert valid 90 days. Re-run this script any time — it renews only when needed."