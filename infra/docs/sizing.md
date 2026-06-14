# Sizing & GPU selection

How the platform turns *"N students + this model"* into *"this many GPU nodes of this
plan."* The wizard encodes this formula (Phase 5); this doc is the reference behind it.

## Decoding a GPU plan name

Akamai GPU plan ids look like `g2-gpu-rtx4000a4-s`. Three independent fields hide in there,
and the colliding `4`s confuse almost everyone:

| Field | Example | Meaning |
|---|---|---|
| `g2` | generation | `g1` = Quadro RTX 6000 (24 GB/card), **`g2` = RTX 4000 Ada (20 GB/card)**, `g3` = RTX PRO 6000 Blackwell (96 GB/card) |
| `rtx4000` | model name | The GPU model. The `4000` is **not** a count — it's the product name. |
| `a4` | **card count** | `a1` = 1 GPU, `a2` = 2 GPUs, `a4` = 4 GPUs. The digit **after the `a`** is how many cards. |
| `-s` / `-m` / `-l` | CPU/RAM wrapper | Changes vCPU + RAM only, **not** VRAM. Same GPUs in all three. |

So `g2-gpu-rtx4000a4-s` = 4× RTX 4000 Ada (4 × 20 = **80 GB VRAM**) with the small CPU/RAM wrapper.

## Relevant plans (verified vs the Linode API, 2026-06-05)

| plan_id | GPUs | VRAM | vCPU | RAM | $/hr | Use |
|---|---|---|---|---|---|---|
| `g2-gpu-rtx4000a1-s` | 1 | 20 GB | 4 | 16 | **$0.52** | **Test / capacity-probe box** |
| `g2-gpu-rtx4000a1-l` | 1 | 20 GB | 16 | 64 | $0.96 | Single-GPU small class |
| `g2-gpu-rtx4000a2-s` | 2 | 40 GB | 8 | 32 | $1.05 | 14–30B models / mid class |
| `g2-gpu-rtx4000a4-s` | 4 | 80 GB | 32 | 128 | $2.96 | **Full class, TP=4 pooled KV (default)** |
| `g2-gpu-rtx4000a4-m` | 4 | 80 GB | 48 | 196 | $3.57 | Full class, more CPU headroom |
| `g3-gpu-rtxpro6000-blackwell-1` | 1 | 96 GB | 16 | 176 | $2.50 | 70B+ on one card (limited availability) |

> **Billing:** effective **2026-07-01**, GPU Linodes go hourly-only (no monthly cap). Plan
> around `$/hr`. Blackwell multi-card slugs are access-gated and unpublished — don't hardcode them.

## The formula

Assumptions: short agent turns, fp8 weights, fp16 KV, `--gpu-memory-utilization 0.9`,
`--max-model-len 8192`, prefix caching ON.

### KV cache sizing

The sizing calculator estimates actual KV cache memory based on model architecture
parameters (from HuggingFace `config.json`), student concurrency, and context length.
This replaced the earlier flat 1.25x VRAM headroom multiplier.

**Per-token KV cache memory (one layer):**

```
kv_per_token = 2 × num_kv_heads × head_dim × kv_dtype_bytes
```

The `2` accounts for both the key and value projections. `kv_dtype_bytes` is 2 (FP16)
for all models — vLLM uses FP16 KV cache regardless of weight quantization.

**Total KV cache (all layers, all concurrent slots):**

```
concurrent_estimate = ceil(students × 0.3)      # ~30% active at any moment
active_slots        = max(concurrent_estimate, 4) # floor of 4 for burst headroom
kv_cache_gb         = (kv_per_token × num_layers × context_len × active_slots) / 1024³
```

The context length used for sizing is 4096 tokens (`KV_SIZING_CONTEXT_LEN`), not the
vLLM `--max-model-len`. Workshop students rarely exceed 4K tokens in a single
conversation turn.

**Total VRAM needed:**

```
total_vram = model_weights_gb + kv_cache_gb + 1.5 GB (framework overhead)
must fit:    total_vram ≤ gpu_pool_vram × 0.9
```

The 1.5 GB framework overhead covers CUDA contexts, the weight loader, and the vLLM
scheduler. The sizing preview shows this breakdown:

```
VRAM: 18 GB weights + 2.25 GB KV cache + 1.5 GB overhead = ~21.8 GB total
```

### Model architecture parameters

Each model in the catalog carries its KV cache architecture (`num_layers`,
`num_kv_heads`, `head_dim`, `kv_dtype_bytes`). These are sourced from HuggingFace
`config.json` and verified for Qwen3-8B, Llama-3.1-8B, and DeepSeek-R1-8B.

| Field | config.json key | Description |
|---|---|---|
| `num_layers` | `num_hidden_layers` | Transformer layer count |
| `num_kv_heads` | `num_key_value_heads` | KV attention heads (GQA uses fewer than query heads) |
| `head_dim` | `head_dim` or `hidden_size / num_attention_heads` | Dimension per attention head |
| `kv_dtype_bytes` | — | Always 2 (FP16 KV cache) |

### VRAM budget

1. **VRAM per replica** = `weights + kv_cache + 1.5 GB`,
   and it must fit inside `0.9 × node_VRAM`.
2. **Students per replica** (conservative planning numbers):
   - 20 GB (1× Ada): **~15**
   - 40 GB (2× Ada): **~40–60**
   - 80 GB (4× Ada, TP=4): **~150–300 short turns**
   - Enrolled ≫ active — students think between turns, so a replica sized for ~20 *active*
     comfortably backs ~40–50 *enrolled*.
3. **Replicas** = `ceil(students / per_replica)`.
4. **TP vs replicas:** if the model fits on one card, prefer many **TP=1** replicas
   (better throughput + fault isolation). Use **TP=N** only when the model won't fit one
   card *or* you want a deep pooled KV cache for bursts. TP must stay within a single node
   and must divide the model's attention-head count.
5. **CPU nodes** = `ceil(students / 16)` on `g6-dedicated-8`.

> **What the calculator actually does** (`infra/scripts/sizing.py`): it provisions **one
> vLLM replica + one CPU node per ~16 students** — a conservative burst-headroom / fault-
> isolation operating point, *not* the raw capacity ceiling above (an 80 GB pool can serve
> far more). Use `make capacity-test` to measure the real number for your model + content
> and raise the ratio to save money. Small classes (≤24) drop to the cheapest GPU plan that
> fits the model instead of the pooled default.

> **Invariant:** `tensor_parallel_size` must equal the GPU count of the chosen GPU plan
> (`a4` → 4). It drives both vLLM's `--tensor-parallel-size` and the pod's `nvidia.com/gpu`
> request.

### Worked example — 80 students, `Qwen/Qwen3-8B-FP8`

- weights ~8 GB; KV ~23 GB at 8K × ~20 active → pooled KV budget wins → **TP=4** on
  `g2-gpu-rtx4000a4-s`.
- 5 replicas for burst headroom + fault isolation = **5 GPU nodes + 5 CPU nodes**.
- 5 × $2.96 (GPU) + 5 × $0.216 (CPU) = **~$15.88/hr** (~$64 for a 4-hour class) at live
  prices. (PLATFORM-PLAN §3 rounds to ~$17.80 using an older, higher CPU-node price.)

## Model catalog (ungated only — no HuggingFace token ever required)

| Tier | HF id | VRAM | Fits |
|---|---|---|---|
| Small | `Qwen/Qwen3-4B-Instruct-2507` | ~12 GB | 1× Ada 20 GB (cheap test) |
| Small | `openai/gpt-oss-20b` (MoE, MXFP4) | ~16 GB | 1× Ada 20 GB |
| Small | `Qwen/Qwen3-8B-FP8` **(default)** | ~18 GB | 1× Ada 20 GB, or TP=4 pool |
| Medium | `Qwen/Qwen3-14B-FP8` | ~28 GB | 2× Ada 40 GB / TP=2 |
| Medium | `Qwen/Qwen3-30B-A3B-Instruct-2507-FP8` (MoE) | ~36 GB | 40 GB pool — high class throughput |
| Medium | `mistralai/Mistral-Small-3.2-24B-Instruct-2506` | ~34 GB | 40 GB pool (vision-capable) |
| Large | `openai/gpt-oss-120b` (MoE, MXFP4) | ~80 GB | 4× Ada TP=4 / Blackwell |

Always cap `--max-model-len` and keep prefix caching on — a shared class system prompt +
tool schemas is a large KV win. Gated models (e.g. Llama 3.x) are intentionally off the
menu to keep the no-token guarantee.

## Inference modes (the `inference` component)

The default `shared-vllm` shape (above) pools ~16 students per replica. Two other modes
reshape the GPU footprint:

- **`dedicated-vllm`** — one **deliberately under-tuned** vLLM per student on their **own
  GPU node**, so the saturate/optimize lab has something to fix. GPU nodes = `students × 1`
  (1 GPU each), **not** `students / 16`. The smallest single-GPU plan that fits the model is
  auto-picked (e.g. `g2-gpu-rtx4000a1-s`, $0.52/hr). Requires `cluster_access: scoped` (each
  vLLM lives in the student's namespace, reached via the in-namespace `vllm` Service). **GPU
  stock bites hardest here** — `students` GPUs in one region; reserve ahead and preflight.

  ```bash
  infra/scripts/sizing.py plan --students 12 --model Qwen/Qwen3-4B-Instruct-2507 \
    --inference dedicated-vllm --gpus-per-student 1 --editor jupyter
  ```

- **`external`** — no platform vLLM and **zero GPU nodes**; the workshop calls a
  user-supplied OpenAI-compatible endpoint (`inference_endpoint` + optional
  `inference_api_key`). The cost preview omits the GPU line entirely (CPU-only).

  ```bash
  infra/scripts/sizing.py plan --students 30 --model Qwen/Qwen3-4B-Instruct-2507 \
    --inference external
  ```

`gpus_per_student: 2` (two models + agentgateway routing) is reserved for v2.

## Multi-model sizing

When deploying multiple models, the sizing calculator computes independent GPU plans
per model and aggregates the costs. CPU nodes are shared across all models.

```bash
# Per-model plans + aggregate cost (JSON for scripting)
infra/scripts/sizing.py multi-plan --students 40 \
  --models "Qwen/Qwen3-8B-FP8,Qwen/Qwen3-14B-FP8" --json

# Human-readable preview
infra/scripts/sizing.py multi-plan --students 40 \
  --models "Qwen/Qwen3-8B-FP8,Qwen/Qwen3-14B-FP8"
```

Each model gets its own GPU node pool with a distinct label (e.g.
`gpu-qwen-qwen3-8b-fp8`). The KV cache is sized independently per model — a model
with more KV heads or layers consumes more VRAM for the same student count.

### Model slugs

Model names are converted to Kubernetes-safe slugs for resource names:
`Qwen/Qwen3-8B-FP8` becomes `qwen-qwen3-8b-fp8`. The slug is lowercase,
non-alphanumeric characters become hyphens, capped at 40 characters. The same
`slugify()` function is used in both `sizing.py` and `deploy.sh`.

## Empirical sizing — `make capacity-test`

The numbers above are conservative planning figures. To get the real
students-per-replica for *your* model + content, run the capacity test against a running
replica (deploy first, or point it at a cheap single-GPU probe):

```bash
make capacity-test ARGS="--model Qwen/Qwen3-8B-FP8 --levels '1 4 8 16 32 64'"
# or directly:
infra/scripts/capacity-test.sh --threshold 8000 --num-prompts 128 --students 80
```

It ramps `--max-concurrency` through the levels, records p50/p99 end-to-end latency and
output tokens/sec at each, and stops at the highest concurrency whose p99 stays under the
threshold (default 10 s). It reports:

- **active_per_replica** — the max concurrency under the p99 threshold.
- **enrolled_per_replica** — ≈2.5× active (students think between agent turns).

Feed `enrolled_per_replica` back into the formula: `replicas = ceil(students / enrolled)`,
then re-deploy with `--gpu-node-count <replicas>`. Two profiles: **generic** (default —
random short turns emulating agent chat, no external download) and **workshop** (replays
prompts from `capacity-prompts.txt` in your content repo if present). The test deploys no
cloud infrastructure itself — it runs an in-cluster Job (`app: capacity-test`, allowed
through the default-deny NetworkPolicy to reach `vllm:8000`).

## Regions & GPU capacity

GPUs are offered in only some Akamai regions, and even those go out of stock. The platform
**never hardcodes a region** — `infra/scripts/regions.sh` discovers and validates live.

```bash
infra/scripts/regions.sh list                          # GPU-capable regions (the menu)
infra/scripts/regions.sh availability g2-gpu-rtx4000a4-s   # advisory per-region stock flags
infra/scripts/regions.sh preflight g2-gpu-rtx4000a4-s us-ord  # verdict + fallbacks
```

Two API signals (both public, no token):

- `GET /v4/regions` — filter `capabilities` for `"GPU Linodes"`. This is the menu of regions
  where GPU is *offered* (21 of 33 today).
- `GET /v4/regions/availability` — live stock flags. **Advisory only:** the feed reads
  `available=false` for essentially every `g1/g2-gpu` plan even when stock exists.
- **Ground truth is the provision attempt.** Capability = "offered"; the availability feed
  is partial; only `terraform apply` succeeding proves stock. The platform provisions the
  GPU pool first so a capacity miss fails fast and never strands a half-built, billing cluster.

**On a capacity failure, three fallbacks (in order):**

1. **Retry in another GPU region** from the live list (`regions.sh list`).
2. **Drop to a smaller GPU plan** — an `a4` may be out while `a1` is in stock; re-plan as
   more TP=1 replicas (the formula above already supports this).
3. **Request capacity** — for large classes or Blackwell, ask the Akamai account team for
   the exact `plan × count` in the region (`regions.sh preflight` prints the line to send).
