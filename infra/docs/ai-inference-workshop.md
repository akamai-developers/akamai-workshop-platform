# AI inference workshop: swap models, use kubectl, read metrics

This is the student-facing guide for the AI inference classroom. Each student gets a
Jupyter workspace, their **own namespace** (`workshop-sNN`), **one dedicated GPU**, and
their **own vLLM** (Deployment `vllm`, reachable in-namespace at `http://vllm:8000`). The
vLLM is deliberately **under-tuned** (`--gpu-memory-utilization=0.7`,
`--max-model-len=8192`, `--max-num-seqs=32`) — testing those knobs is part of the lab.

Models you select with `--predownload-models` at deploy time are pre-pulled into each
student's PVC. The BF16 and FP8 4B models are served-model targets, so switching between
them is a fast restart-from-cache. The 0.6B model is cached only for speculative decoding
as a drafter.

## Deploy the classroom (operator)

```bash
export TF_VAR_token="$LINODE_TOKEN"
./deploy.sh deploy --yes \
  --students 200 --editor jupyter \
  --inference dedicated-vllm --cluster-access scoped \
  --gpus-per-student 1 \
  --model Qwen/Qwen3-4B \
  --predownload-models 'Qwen/Qwen3-4B,RedHatAI/Qwen3-4B-FP8-dynamic,RedHatAI/Qwen3-0.6B-FP8-dynamic' \
  --domain "" --region us-ord
```

`--inference dedicated-vllm` requires `--cluster-access scoped`. The model in `--model`
is what each vLLM serves at startup. Keep `model_cache_size` (default `50Gi`) larger than
the sum of the listed models — the three Qwen3 models above total ~10 GB.

Plan and price it first (creates nothing):

```bash
make dry-run ARGS="--students 200 --model Qwen/Qwen3-4B \
  --inference dedicated-vllm --gpus-per-student 1 --editor jupyter"
```

## 1. Swap the model your vLLM serves

A vLLM process serves **one model**, fixed by `--model` at startup — there is no way to
hand a running server a different model name and have it hot-load. "Switching" means
**restarting** the server with a new `--model`. Because the model is already in your PVC
(pre-downloaded), the restart loads from cache in seconds instead of re-downloading.

Both served-target workshop models are Qwen3 "thinking" models, so the reasoning/tool-call
parser flags stay correct as you switch between them.

**From a notebook** (helpers ship in the content repo at `common/vllm_admin.py`):

```python
from common.vllm_admin import switch_model, current_model, AVAILABLE_MODELS

current_model()                              # what is loaded now
AVAILABLE_MODELS                             # the pre-cached served-model choices
switch_model("RedHatAI/Qwen3-4B-FP8-dynamic") # patch --model, restart, wait for Ready
```

After a switch, pass the **new** model id in your OpenAI client calls:

```python
from openai import OpenAI
client = OpenAI(base_url="http://vllm:8000/v1", api_key="not-needed")
client.chat.completions.create(model="RedHatAI/Qwen3-4B-FP8-dynamic",
    messages=[{"role": "user", "content": "hi"}], max_tokens=16)
```

**The raw kubectl** the helper runs (for the kubectl-teaching labs — prefix with `!` in a
notebook cell):

```bash
!kubectl patch deployment vllm --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/args/0","value":"--model=RedHatAI/Qwen3-4B-FP8-dynamic"}]'
!kubectl rollout status deployment/vllm
```

## 2. Using kubectl inside your namespace

Your workspace has a scoped kubeconfig mounted at `~/.kube/config`; its current context is
already your own namespace, so kubectl commands need no `-n` flag and only touch **your**
resources. You run as `serviceaccount:workshop-sNN:student`.

| Command | Allowed? | What it does |
|---|---|---|
| `kubectl get pods` / `get deploy` / `get svc` | ✅ | see your vLLM + workspace |
| `kubectl logs deploy/vllm` | ✅ | watch vLLM start up / load the model |
| `kubectl describe pod <pod>` | ✅ | events, why a pod is Pending |
| `kubectl scale deploy/vllm --replicas=0\|1` | ✅ | stop / start your vLLM |
| `kubectl patch deployment vllm ...` | ✅ | change `--model` or tuning flags |
| `kubectl port-forward deploy/vllm 8000` | ✅ | reach vLLM from a local terminal |
| `kubectl get nodes` | ❌ Forbidden | cluster-scoped — denied **by design** |
| `kubectl get pods -n kube-system` | ❌ Forbidden | other namespaces — denied by design |

`kubectl get nodes` returning **Forbidden** is the isolation fence working, not a failure.

**Tune your vLLM** (the saturate/optimize lab — raise the under-tuned defaults):

```bash
# raise the running sequence cap 32 -> 128 (more requests can run together)
!kubectl patch deployment vllm --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/args/5","value":"--max-num-seqs=128"}]'

# optionally raise GPU memory utilization 0.7 -> 0.9 (more KV cache)
!kubectl patch deployment vllm --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/args/3","value":"--gpu-memory-utilization=0.9"}]'

!kubectl rollout status deployment/vllm
```

The arg order is `--model` (index 0), `--download-dir` (1), `--tensor-parallel-size` (2),
`--gpu-memory-utilization` (3), `--max-model-len` (4), `--max-num-seqs` (5). If a tune makes vLLM crash at
startup ("no available memory for cache blocks"), lower the value — that failure *is* the
lesson.

## 3. Reading metrics: TTFT, TPS, and more

vLLM serves a Prometheus metrics endpoint at **`http://vllm:8000/metrics`** (plain text).
The workshop NetworkPolicy already allows your workspace to reach it, so you can read it
straight from the notebook — no Prometheus or Grafana required.

**From a notebook** (helpers ship in the content repo at `common/metrics.py`):

```python
from common.metrics import vllm_stats, watch

# run some inference, then measure the recent averages over a 5s window:
vllm_stats(window_s=5)
# -> {'ttft_s': 0.08, 'tpot_s': 0.012, 'e2e_latency_s': 0.9,
#     'gen_tokens_per_s': 240.0, 'running': 2, 'waiting': 0}

# sample + plot TTFT over 60s while you drive load from another cell:
watch(60)
```

**Raw** — TTFT is a histogram, so its `_sum / _count` is the running average; tokens/sec
(TPS) is the rate of the generation-token counter:

```bash
!curl -s http://vllm:8000/metrics | grep -E 'time_to_first_token_seconds_(sum|count)'
!curl -s http://vllm:8000/metrics | grep generation_tokens_total
```

### vLLM metrics reference

Metric names vary slightly by vLLM version — confirm yours with
`!curl -s http://vllm:8000/metrics | grep <keyword>`.

**1. Request latency & performance (histograms).** Tracked as distributions, so you can
read p50 / p90 / p99.

| Metric | Meaning |
|---|---|
| `vllm:time_to_first_token_seconds` | **TTFT** — prefill time before streaming starts |
| `vllm:time_per_output_token_seconds` | **TPOT** — per-token streaming latency (some versions: `vllm:inter_token_latency_seconds`) |
| `vllm:e2e_request_latency_seconds` | total turnaround, request in → final token out |
| `vllm:request_queue_time_seconds` | time waiting in the scheduler queue before execution |
| `vllm:request_prefill_time_seconds` / `vllm:request_decode_time_seconds` | isolated prefill vs decode intervals |

**2. Traffic & token throughput (counters).** Cumulative totals — use Prometheus
`rate()` (or a delta over a window) for real-time throughput / TPS.

| Metric | Meaning |
|---|---|
| `vllm:prompt_tokens_total` | total input tokens processed |
| `vllm:generation_tokens_total` | total output tokens generated (→ TPS via `rate()`) |
| `vllm:request_success_total` | successful completions, labeled by `finished_reason` (stop vs length) |

**3. Engine scheduler status (gauges).** Real-time allocation and bottleneck state.

| Metric | Meaning |
|---|---|
| `vllm:num_requests_running` | requests batched on the GPU right now |
| `vllm:num_requests_waiting` | requests queued because the GPU is full |
| `vllm:num_requests_swapped` | requests evicted to CPU RAM under KV-cache pressure |
| `vllm:num_preemptions_total` | times lower-priority requests were preempted for capacity |

**4. Cache & memory efficiency (gauges).** PagedAttention and prefix-cache health.

| Metric | Meaning |
|---|---|
| `vllm:kv_cache_usage_perc` | fraction of KV cache in use (0–1); nearing 1.0 means requests start queuing |
| `vllm:prefix_cache_queries_total` | prompt segments checked against the prefix cache |
| `vllm:prefix_cache_hits_total` | reused tokens from prior prompts (skipped prefill) |

### Triage

If `vllm:num_requests_waiting` spikes while `vllm:kv_cache_usage_perc` sits near `1.0`,
you are out of KV-cache memory: requests are queuing, not running. Lower `--max-model-len`
(smaller per-request KV footprint) or raise `--gpu-memory-utilization` (more KV cache) —
both via the kubectl patches in section 2 — or scale horizontally. A healthy server keeps
`kv_cache_usage_perc` below ~0.9 with `num_requests_waiting` at or near `0`.

## Updating workshop content (latest, or a branch / PR)

Workspaces clone the content repo once at pod start, so new commits or branches don't
appear on running pods automatically. Two ways to update — no redeploy, no pod recreation:

**All students** — roll the latest `main`, or a specific branch/PR head, into every workspace:

```bash
make refresh-content                                                # latest main
make refresh-content ARGS="--ref feat/modules-5-8-performance-arc"  # a branch / PR head
```

`refresh-content` force-checks-out the ref in every `app=workspace` pod. (Use `--keep-edits`
for a fast-forward `main` pull that preserves in-pod edits — but that can't switch branches.)

**One student** — e.g., to test a branch on a single workspace before rolling it out:

```bash
KUBECONFIG=infra/kubeconfig.yaml kubectl -n workshop-sNN exec ws-NN -- sh -lc \
  'cd /home/coder/workshop && git fetch --depth=1 origin <branch> && git checkout -f FETCH_HEAD'
# student 204 onto the performance-arc PR:
#   kubectl -n workshop-s204 exec ws-204 -- sh -lc \
#     'cd /home/coder/workshop && git fetch --depth=1 origin feat/modules-5-8-performance-arc && git checkout -f FETCH_HEAD'
```

After either, students **refresh the Jupyter file browser** to see the new files. The content
repo is public, so the in-pod fetch needs no token — just the operator kubeconfig.

## See also

- [`gpu-sharing.md`](gpu-sharing.md) — running two models on one GPU (time-slicing lab)
- [`sizing.md`](sizing.md) — the model catalog and GPU-plan math
- [`troubleshooting.md`](troubleshooting.md) — when a pod stays Pending or vLLM won't start
