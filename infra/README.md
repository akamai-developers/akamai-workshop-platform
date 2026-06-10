# AI Agents Workshop — Infrastructure

Terraform + Kubernetes infrastructure for running the workshop on Akamai Cloud (Linode).

## Architecture

```
Student Browser
    │ HTTPS (wildcard cert *.<base-host>)
    ▼
NodeBalancer  (public IP, 80/443)
    │
    ▼
ingress-nginx Controller (subdomain routing)
    ├── s01.<base-host> → ws-01 pod  (code-server, per-student password)
    ├── s02.<base-host> → ws-02 pod
    │   ...
    └── s80.<base-host> → ws-80 pod
         │
         └── http://vllm:8000/v1 → vLLM StatefulSet (Qwen3-8B-FP8)

LKE Cluster
    ├── CPU Pool  (5x g6-dedicated-8 — 16GB, 8 vCPU)
    │   └── 80x workspace pods + ingress-nginx + system pods
    │
    └── GPU Pool  (5x g2-gpu-rtx4000a4-s — 4× RTX 4000 Ada per node, 20GB VRAM each)
        └── 5x vLLM replicas, each one spans 4 GPUs via tensor parallelism
              (--tensor-parallel-size=4), and has its own 50Gi PVC for model
              cache (StatefulSet + volumeClaimTemplates).
```

Cluster-level: `gpu-operator` (NVIDIA drivers + device plugin),
`cloud-firewall-controller` (worker node firewall),
`ingress-nginx`, NetworkPolicy (default-deny + explicit allow rules).

## Prerequisites

- [Terraform](https://terraform.io) >= 1.5
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Docker](https://docker.com) (for building the workspace image)
- [lego](https://go-acme.github.io/lego/) — `brew install lego` (for wildcard TLS via Linode DNS-01)
- [Linode API token](https://cloud.linode.com/profile/tokens) (full access, scoped to your account)
- [GitHub PAT](https://github.com/settings/tokens) — **classic** PAT (fine-grained tokens have known issues with ghcr.io), scopes: `write:packages`, `read:packages`, `delete:packages`
- (Domain mode only) a domain managed in Linode DNS. No-domain mode uses sslip.io + self-signed TLS and needs no domain.

## Quick Start

```bash
# 1. Set API token — Read/Write on: Kubernetes, Linodes, Firewalls, NodeBalancers,
#    Volumes, and Domains (Domains drives the Let's Encrypt DNS-01 challenge).
#    TF_VAR_token and LINODE_TOKEN are interchangeable; you only need one.
export TF_VAR_token="your-linode-api-token"

# 2. Log docker into ghcr.io
echo "<your-github-pat>" | docker login ghcr.io -u <your-github-username> --password-stdin

# 3. Provision cluster + vLLM + DNS (~20-25 min)
./scripts/provision.sh

# 4. Issue wildcard TLS cert (~1-2 min, idempotent — safe to re-run)
./scripts/issue-cert.sh
kubectl -n workshop get secret workshop-tls   # confirm it exists

# 5. (OPTIONAL) Build + push a dedicated workspace image (~5 min).
#    Skip this — workspaces default to the stock codercom/code-server image with
#    startup.sh mounted from a ConfigMap (content is cloned at pod startup). Build
#    one only for faster pod start. Needs Docker + a registry login.
#    export REGISTRY=ghcr.io/<your-org> && ./scripts/build-workspace-image.sh
#    Then set the package PUBLIC (or add an imagePullSecret) and pass --image to step 6.

# 6. Generate ONE student workspace to verify end-to-end
./scripts/generate-pods.sh -n 1 --host <base-host>
kubectl apply -f manifests/generated/
cat manifests/generated/access-cards.csv     # URL + password for s01

# 7. Validate (open https://s01.<base-host> in a browser, log in, run 00_verify.py)
./scripts/health-check.sh

# 8. Scale to 80 once s01 works end-to-end. generate-pods.sh is idempotent:
#    s01's password is preserved, and only s02–s80 get newly minted passwords.
./scripts/generate-pods.sh -n 80 --host <base-host>
kubectl apply -f manifests/generated/

# 9. Print access cards
./scripts/print-access-cards.sh

# 10. Measure students-per-replica (optional)
./scripts/capacity-test.sh
```

### About the TLS cert (step 4)

`./scripts/issue-cert.sh` uses [lego](https://go-acme.github.io/lego/) + Linode DNS-01 to issue a wildcard Let's Encrypt cert for `*.<base-host>`, then stores it as the `workshop-tls` K8s Secret. The Ingress (generated in step 6) references that Secret.

- **Idempotent**: re-run any time. If a cert exists locally in `.certs/`, lego will renew if near expiry, otherwise skip.
- **Token source order**: `TF_VAR_token` env → `LINODE_TOKEN` env → `terraform/terraform.tfvars`. Each candidate is probed against the Linode API and the first one that is valid **and** can list Domains wins; invalid or under-scoped candidates are skipped with a warning. The two env vars are interchangeable — you only need one.
- **Required scopes on the token**: `Domains: Read/Write`. The script validates this before calling lego.
- **`provision.sh` also tries to call this** at its final step, but as best-effort — if lego isn't installed, or the token lacks DNS scope, it logs a warning and continues. **Always confirm the secret exists** with `kubectl get secret workshop-tls -n workshop` before applying the Ingress.
- **Renewal**: cert is valid 90 days. Re-run `./scripts/issue-cert.sh` to renew.

## Cost Estimate

Linode list pricing, US-Ord region, May 2026:

| Resource | Plan | Count | $/hr | $/4hr workshop |
|----------|------|-------|------|----------------|
| CPU Nodes | g6-dedicated-8 (16GB) | 5 | $0.216 | $4.32 |
| GPU Nodes | g2-gpu-rtx4000a4-s (4× RTX 4000 Ada, 20GB each) | 5 | $2.94 | $58.72 |
| NodeBalancer | Standard | 1 | $0.015 | $0.06 |
| Block Storage | 50Gi × 5 PVCs | — | — | ~$0.07 |
| **Total** | | | | **~$63** |

(For tighter budgets, drop `gpu_node_type` to `g2-gpu-rtx4000a1-s` and set `--tensor-parallel-size=1` — 5 GPUs instead of 20, ~$15/4hr. Latency under burst load rises (TP=1 has no pooled KV cache to absorb spikes) — re-measure for your model with `make capacity-test`.)

Run `./scripts/teardown.sh` immediately after the workshop to stop billing.

## Mid-workshop Operations

Common operations once the cluster is up. None of these require a full teardown.

### Regenerate manifests after editing the pod template

`workspace-pod-template.yaml` is the source for every student pod. After editing it (or `vllm-statefulset.yaml`, or any other config), re-emit and re-apply:

```bash
./scripts/generate-pods.sh -n 80 --host <base-host>   # passwords preserved
kubectl apply -f manifests/generated/
```

Re-running `generate-pods.sh` is idempotent: existing passwords in `access-cards.csv` are preserved and only new students (if `-n` grew) get fresh passwords. To force-rotate all passwords (e.g., between cohorts) pass `--rotate`; the previous CSV is archived to `access-cards.csv.bak`. To trim below the current count pass `--shrink`. Changing `--host` requires `--rotate`.

### Restart a single workspace pod

If one student's environment gets wedged. Bare Pods aren't managed by a Deployment, so `delete pod` is permanent — re-applying the manifest recreates it (existing pods are no-ops):

```bash
kubectl -n workshop delete pod ws-NN
kubectl apply -f manifests/generated/workspace-manifests.yaml
```

### Reset a single student's password

`generate-pods.sh` is all-or-nothing (no per-student rotate flag, by design). To reset one student manually:

```bash
NEW=$(openssl rand -hex 16)
kubectl -n workshop create secret generic ws-NN-password \
  --from-literal=password="${NEW}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n workshop delete pod ws-NN                              # pick up the new secret
kubectl apply -f manifests/generated/workspace-manifests.yaml     # recreate
echo "sNN,https://sNN.<base-host>/,${NEW}"            # hand-edit access-cards.csv
```

### Restart vLLM

```bash
kubectl -n workshop rollout restart statefulset/vllm
```

### Delete all workspaces, keep the cluster + vLLM + cert

For an unplanned reset mid-workshop, or to recycle the cluster between cohorts without paying the 20-minute provision tax again:

```bash
kubectl delete -f manifests/generated/workspace-manifests.yaml
kubectl delete -f manifests/generated/workspace-secrets.yaml
kubectl delete -f manifests/generated/ingress.yaml
# Optionally also: rm manifests/generated/access-cards.csv  (keeps a .bak around)
```

LKE, GPU pool, NodeBalancer, vLLM, and the TLS Secret are all untouched. Re-run `generate-pods.sh` (with `--rotate` for fresh passwords) and `kubectl apply -f manifests/generated/` to bring workspaces back.

### Full teardown

```bash
./scripts/teardown.sh
```

Destroys the LKE cluster, GPU pool, NodeBalancer, PVCs, and the `manifests/generated/` directory. Use this after the workshop ends — billing keeps running otherwise.

## Security Model

- **Namespace PodSecurity**: `baseline` enforced, `restricted` warn/audit
- **NetworkPolicy**: default-deny ingress; explicit allow `ingress-nginx → workspaces:8080`
  and `workspaces → vllm:8000`; everything else blocked
- **Workspace pods**: non-root (UID 1000), no privilege escalation, all capabilities dropped, `seccomp=RuntimeDefault`
- **TLS**: wildcard Let's Encrypt cert (`*.workshop.<domain>`) via lego + Linode DNS-01
- **Worker node firewall**: managed by `cloud-firewall-controller` — blocks NodePort range from internet
- **vLLM is internal-only**: ClusterIP service, never exposed publicly. No API key needed; NetworkPolicy is the perimeter.
- **Unique per-student passwords**: 128-bit random hex (32 chars) generated by `generate-pods.sh`, one per workspace, stored as K8s Secrets, mounted as `PASSWORD` env var
- **Cluster destroyed after workshop** via `teardown.sh`

## File Structure

```
infra/
├── terraform/
│   ├── main.tf                # LKE + GPU pool + helm releases + DNS records
│   ├── variables.tf
│   ├── outputs.tf
│   ├── versions.tf            # Provider pinning
│   └── terraform.tfvars.example
├── helm/                      # values-driven chart for the shared cluster resources
│   ├── Chart.yaml
│   ├── values.yaml            # model, image, replicas, tensor_parallel_size, namespace, …
│   └── templates/             # namespace, networkpolicy, vllm-service, vllm-statefulset, secret
├── manifests/
│   ├── secret.example.yaml    # reference for vllm-secrets (chart renders the real one)
│   ├── workspace-pod-template.yaml  # consumed by generate-pods.sh; mounts startup.sh ConfigMap
│   ├── capacity-test-job.yaml # parametric concurrency ramp → students-per-replica
│   └── generated/             # output of generate-pods.sh (gitignored)
├── images/
│   └── workspace/
│       ├── Dockerfile         # code-server + python3 + git + startup.sh (NO content)
│       └── startup.sh         # clones $CONTENT_REPO at pod start; also used via ConfigMap
├── scripts/
│   ├── provision.sh           # one-shot: terraform → helm render/apply → vllm → cert
│   ├── teardown.sh            # one-shot: PVCs → ns → terraform destroy
│   ├── build-workspace-image.sh  # OPTIONAL: docker build + push the generic image
│   ├── regions.sh             # live GPU region discovery + capacity preflight (Linode API)
│   ├── sizing.py              # students+model → GPU plan/TP/node counts/$/hr (wizard calls this)
│   ├── issue-cert.sh          # wildcard TLS: self-signed (no-domain) or lego + Linode DNS
│   ├── generate-pods.sh       # emit N student workspaces + startup ConfigMap; idempotent passwords
│   ├── print-access-cards.sh  # printable HTML from access-cards.csv
│   ├── health-check.sh        # end-to-end smoke test
│   ├── pre-warm.sh            # touch each vLLM replica to load CUDA graphs
│   └── capacity-test.sh       # ramp concurrency → students-per-replica (parametric Job)
└── docs/
    ├── architecture.md
    ├── sizing.md
    ├── runbook.md
    ├── security.md
    └── troubleshooting.md
```

## What Terraform actually provisions

Single `terraform apply` from `terraform/`:

| Resource | Purpose |
|---|---|
| `linode_lke_cluster.workshop` | LKE control plane + inline CPU pool |
| `linode_lke_node_pool.gpu` | Separate GPU pool with `pool=gpu` label |
| `linode_firewall.ingress` | Optional firewall for the LB (not attached by default — see comment in main.tf) |
| `helm_release.cloud_firewall_crd` + `cloud_firewall_controller` | Per-node firewalls on workers |
| `helm_release.gpu_operator` | NVIDIA drivers + device plugin DaemonSets |
| `helm_release.ingress_nginx` | ingress-nginx controller + NodeBalancer |
| `data.kubernetes_service.ingress_lb` | Reads the LB's public IP for `base_host` / DNS records |
| `linode_domain_record.workshop_wildcard` | `*.<prefix>.<domain>` → LB IP (**domain mode only**, `count=0` when `domain=""`) |
| `linode_domain_record.workshop_apex` | `<prefix>.<domain>` → LB IP (**domain mode only**, `count=0` when `domain=""`) |

In no-domain mode (`domain=""`, the default), no DNS records are created — student URLs use
`sNN.<lb-ip-dashed>.sslip.io` (the `base_host` output) with a self-signed wildcard cert.

## Documentation

- [Quickstart](docs/quickstart.md) — deploy → port-forward → teardown (both domain modes)
- [Architecture](docs/architecture.md) — layers, the Helm chart, what's a value
- [Sizing](docs/sizing.md) — GPU plan decode, the sizing formula, model catalog, regions
- [Cost](docs/cost.md) — $/hr breakdown + how to keep the bill down
- [Runbook](docs/runbook.md) — Day-of checklist
- [Security](docs/security.md) — Threat model + controls
- [Troubleshooting](docs/troubleshooting.md) — Common issues
