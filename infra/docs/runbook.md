# Classroom-day runbook

A timeline for running a class of **N students**. Times are relative to class start
(`T+0`); compress them for a small class. Cold start (cluster + GPU operator + model
download) is ~15–20 min, so you don't need to provision hours early. GPU nodes bill by the
hour — see [cost.md](cost.md).

## T-1h to T-20m: Deploy

```bash
export TF_VAR_token="your-linode-api-token"

# Preview the plan + cost without creating anything:
./deploy.sh --dry-run --students N --model Qwen/Qwen3-8B-FP8

# Deploy (interactive prompts + cost confirm), or headless with a config:
make deploy
#   or: ./deploy.sh --yes --config config.yaml
```

The wizard provisions the LKE cluster (CPU + GPU pools), gpu-operator, ingress-nginx
(+ NodeBalancer), the vLLM StatefulSet, wildcard TLS, and the per-student workspaces, then
writes `infra/manifests/generated/access-cards.csv`. Expect node counts to match the sizing
preview (e.g. 80 students → 5 GPU + 5 CPU nodes).

## T-15m: Validate

```bash
./scripts/health-check.sh        # vLLM ready, /health 200, a test completion returns text
```

Optionally measure real capacity for this model + content (see [sizing.md](sizing.md)):

```bash
make capacity-test ARGS="--students N"
```

## T-10m: Smoke-test one workspace

1. Open `https://s01.<base-host>/` in a browser (`<base-host>` is printed at the end of
   deploy and in `access-cards.csv`). In no-domain mode the cert is self-signed: **accept the
   browser warning once**, then code-server and its WebSockets work.
2. Log in with the password from `access-cards.csv`.
3. Confirm the content repo cloned into the workspace and that a call to
   `http://vllm:8000/v1` from a terminal in the workspace returns a completion.

Re-running `generate-pods.sh` is idempotent — existing passwords in `access-cards.csv` are
preserved, bumping `-n` only mints passwords for new students. Use `--rotate` to mint fresh
passwords for everyone (e.g. between cohorts); the previous CSV is archived to `.bak`.

## T-5m: Hand out access cards

```bash
./scripts/print-access-cards.sh           # → infra/manifests/generated/access-cards.html
```

Open the HTML and print, or share `access-cards.csv`. Each student gets their own
`sNN.<base-host>` URL + password.

## T+0: Class begins

Students open their URL, accept the cert warning (no-domain mode), log in, and work through
the content cloned into their workspace. Inference is reached at `http://vllm:8000/v1` from
inside the workspace.

## T+end: Tear down (stops billing)

```bash
make teardown            # or ./deploy.sh teardown
linode-cli lke clusters-list   # verify nothing lingers
```

## Emergency procedures

| Scenario | Action |
|---|---|
| vLLM pod crash | `kubectl -n <ns> rollout restart statefulset/vllm` |
| Student can't connect | `kubectl -n <ns> get pod ws-NN` (and see [troubleshooting.md](troubleshooting.md)) |
| All workspaces down | Check CPU nodes: `kubectl get nodes` |
| No GPU capacity at deploy | Retry another region / smaller plan — see [sizing.md](sizing.md) |
| Total infra failure | Fall back to a local model (e.g. Ollama on the instructor's laptop) |

`<ns>` is the namespace (`workshop` by default).
