# Quickstart

Deploy a classroom, hand out access cards, and tear it down. The no-domain path
(sslip.io + self-signed TLS) needs no DNS and no registry.

## Prerequisites

- A [Linode API token](https://cloud.linode.com/profile/tokens). No-domain mode needs
  Kubernetes / Linodes / NodeBalancers / Volumes: Read-Write. Domain mode also needs
  Domains: Read-Write.
- `terraform` ≥ 1.5, `kubectl`, `helm`, `bash`, `python3`, `openssl` — all on PATH.
- No HuggingFace token (ungated models only). No Docker. No registry login.

```bash
export TF_VAR_token="your-linode-api-token"   # never written to a file by the wizard
```

## 1. Preview (creates nothing)

```bash
./deploy.sh --dry-run --students 80 --model Qwen/Qwen3-8B-FP8
```

Prints the GPU plan, node counts, and `$/hr` estimate. See the ungated model menu with:

```bash
python3 infra/scripts/sizing.py catalog
```

## 2. Deploy

Interactive — answer the five questions, confirm the cost preview:

```bash
make deploy            # or ./deploy.sh
```

Non-interactive — copy and edit the config, then run headless:

```bash
cp config.example.yaml config.yaml
./deploy.sh --yes --config config.yaml
```

The wizard runs a live GPU-capacity preflight, writes `infra/terraform/terraform.tfvars`
and `infra/manifests/generated/helm-values.yaml`, then provisions:
LKE cluster → GPU + CPU pools → gpu-operator → ingress-nginx (+ NodeBalancer) → vLLM
StatefulSet → wildcard TLS → per-student workspaces.

When it finishes you get:

- `infra/manifests/generated/access-cards.csv` — `student_number,url,password`
- `infra/kubeconfig.yaml` — cluster kubeconfig

Student URLs are `s01.<base-host>`, `s02.<base-host>`, … where `<base-host>` is
`<lb-ip-dashed>.sslip.io` (no domain) or `<prefix>.<domain>` (domain mode). In no-domain
mode the cert is self-signed: **open the URL, accept the browser warning once, then log in**
— after that, code-server and its WebSockets work normally.

Printable cards:

```bash
infra/scripts/print-access-cards.sh   # → infra/manifests/generated/access-cards.html
```

## 3. Off-cluster inference access (port-forward)

vLLM is private by design — `ClusterIP` + default-deny NetworkPolicy, no public endpoint.
Students reach it as `http://vllm:8000/v1` from inside their code-server. To call it from
your laptop, tunnel through the API server (the NetworkPolicy doesn't block port-forward):

```bash
export KUBECONFIG=infra/kubeconfig.yaml
kubectl -n workshop port-forward svc/vllm 8000:8000
# in another terminal:
curl http://localhost:8000/v1/models
curl http://localhost:8000/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen3-8B-FP8","messages":[{"role":"user","content":"hi"}]}'
```

There is intentionally no public inference URL and no API key.

## 4. Tear down (stops billing)

```bash
make teardown          # or ./deploy.sh teardown
```

Destroys the cluster, NodeBalancer, and volumes, and removes the local kubeconfig and
generated manifests. Run this when the class ends — GPU nodes bill by the hour. Verify
nothing lingers:

```bash
linode-cli lke clusters-list
```

## Domain mode (optional upgrade)

Set a `domain` (and `cert_email`) in `config.yaml` or via `--domain` / `--cert-email`. The
domain must already exist as a zone in Linode DNS, and the token needs Domains: Read-Write.
The platform then creates the wildcard + apex A records and issues a Let's Encrypt wildcard
via lego (DNS-01) — students get a trusted cert with no browser warning. Everything else is
identical; the TLS secret is `workshop-tls` in both modes.

## Troubleshooting

- **No GPU capacity in the region** — the preflight is advisory; the provision attempt is
  ground truth. On a capacity error, retry another region (`infra/scripts/regions.sh list`),
  drop to a smaller GPU plan, or request capacity. See [sizing.md](sizing.md).
- **vLLM pod slow to become Ready** — first start downloads the model to a PVC (5–10 min).
- More in [troubleshooting.md](troubleshooting.md).
