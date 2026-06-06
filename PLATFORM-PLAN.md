# akamai-workshop-platform — redesign blueprint

> Turning this repo from a single AI-agents *workshop* into a **content-agnostic
> platform** that spins up per-student code-servers + GPU vLLM inference on
> Akamai LKE, self-service, for any workshop content.

Status: **planning complete, build not started.** This file is the durable plan.

---

## 1. What it becomes

The platform owns the hard part — per-student browser IDEs, GPU inference, URLs +
passwords, TLS, networking on LKE. You point it at **any content repo**; your
AI-agents workshop is just the default content, not the product.

A user runs an interactive wizard, answers a handful of questions, and gets a
running classroom + a CSV of student URLs/passwords. One command tears it down.

### Locked decisions
| Decision | Choice |
|---|---|
| Audience | Public / open-source — assume **no domain, no registry, fresh Linode account** |
| Repo name/framing | `akamai-workshop-platform` (content-agnostic substrate) |
| Interface | **Interactive wizard** (two verbs: `deploy`, `teardown`) |
| Sizing | **Autopilot + confirm**, backed by an empirical `capacity-test` |
| Content delivery | **Clone at pod startup** from a configurable `content_repo` URL |
| Default content | `github.com/akamai-developers/ai-agents-workshop` |
| Workspace image | **One prebuilt public generic image** (code-server + python + git); building is an optional advanced path |
| Duplicate content folders | **Cut** `workshop/ src/ docs/ extend/ reference/` → one `examples/` pointer |
| Model menu | **Ungated only** (no HuggingFace token ever required) |
| Default model | `Qwen/Qwen3-8B-FP8` |
| No-domain mode | `sslip.io` hostnames + self-signed wildcard TLS (default) |
| Domain mode | Linode DNS + Let's Encrypt wildcard (opt-in upgrade) |
| Cost safety | Preview $/hr + est. class cost; manual `make teardown` |
| Inference access | **Cluster-internal only** (ClusterIP + default-deny NetworkPolicy). Laptop access via documented `kubectl port-forward`. **No public inference endpoint / no API key** (non-goal). |

---

## 2. The user experience (wizard flow)

```
$ make deploy        # or ./deploy.sh

  How many students?                      → 80
  Which model?  [Qwen3-8B-FP8]            → (enter for default, or pick from menu)
  Workshop content repo?  [ai-agents]     → (enter for default, or paste a URL)
  Do you have a domain?  [no]             → no  (sslip.io + self-signed)
  Region?  [auto: nearest GPU region]     → us-sea

  ── Sizing (autopilot) ───────────────────────────────
  Model Qwen3-8B-FP8  ·  ~18 GB  ·  ungated
  80 students  →  5 vLLM replicas  ·  5× g2-gpu-rtx4000a4-s (TP=4, 80 GB pool each)
                  5× g6-dedicated-8 CPU nodes (code-servers)
  Est. cost: ~$17.80/hr  ·  ~$71 for a 4-hour class
  URLs: s01..s80.<lb-ip>.sslip.io  (self-signed: students accept warning once)

  [c]onfirm   [s]ize differently   [t]est capacity first   [q]uit  →
```

- **`t` / capacity-test** spins up ONE single-GPU box, measures real
  students-per-replica for *this* model + content, and re-runs the math.
- **confirm** → writes `terraform.tfvars` + Helm values → `provision.sh` →
  `generate-pods.sh` → prints `access-cards.csv`.

`make teardown` destroys everything.

### Inputs (the entire user surface)
```yaml
students:     80
model:        Qwen/Qwen3-8B-FP8        # from ungated menu, or any HF id
content_repo: ""                        # "" → default ai-agents-workshop
domain:       ""                        # "" → sslip.io self-signed; else Linode DNS + LE
region:       ""                        # "" → wizard lists LIVE GPU-capable regions (see §6.5)
```
No HF token (ungated only). No registry login (prebuilt public image). No Docker.

---

## 3. Sizing — the part people don't understand

### GPU plan name decode
Pattern `g2-gpu-rtx4000a4-s`:
- **`g2`** = generation. g1 = Quadro RTX 6000 (24 GB/card), **g2 = RTX 4000 Ada (20 GB/card)**, g3 = RTX PRO 6000 Blackwell (96 GB/card).
- **`a4`** = **card count** (a1 = 1 GPU, a2 = 2, a4 = 4). The "4000" is the model name — the *second* digit (after `a`) is how many cards. (The colliding 4s are what confuse everyone.)
- **`-s/-m/-l`** = CPU+RAM wrapper around the **same** GPUs. Only changes vCPU/RAM, not VRAM.

### Relevant plans (verified vs Linode API, 2026-06-05)
| plan_id | GPUs | VRAM | vCPU | RAM | $/hr | Use |
|---|---|---|---|---|---|---|
| `g2-gpu-rtx4000a1-s` | 1 | 20 GB | 4 | 16 | **$0.52** | **Test / capacity-probe box** |
| `g2-gpu-rtx4000a1-l` | 1 | 20 GB | 16 | 64 | $0.96 | Single-GPU small class |
| `g2-gpu-rtx4000a2-s` | 2 | 40 GB | 8 | 32 | $1.05 | 14–30B models / mid class |
| `g2-gpu-rtx4000a4-s` | 4 | 80 GB | 32 | 128 | $2.96 | **Full class, TP=4 pooled KV (repo default)** |
| `g2-gpu-rtx4000a4-m` | 4 | 80 GB | 48 | 196 | $3.57 | Full class, more CPU headroom |
| `g3-gpu-rtxpro6000-blackwell-1` | 1 | 96 GB | 16 | 176 | $2.50 | 70B+ on one card (limited availability) |

> **Billing:** effective **2026-07-01** GPU Linodes go hourly-only (no monthly cap). Plan around $/hr. Blackwell is access-gated; don't hardcode its multi-card slugs (unpublished).

### The formula the wizard encodes
Assume short agent turns, fp8 weights, fp16 KV, `--gpu-memory-utilization 0.9`, `--max-model-len 8192`, prefix caching ON.

1. **VRAM/replica** = `weights + (per_token_KV × max_len × active_slots) + 1.5 GB`, must fit `0.9 × node_VRAM`.
2. **Students per replica** (conservative planning numbers):
   - 20 GB (1× Ada): **~15** · 40 GB (2× Ada): **~40–60** · 80 GB (4× Ada TP=4): **~150–300 short turns**.
   - Enrolled ≫ active (students think between turns): a replica sized for ~20 *active* backs ~40–50 *enrolled*.
3. **Replicas** = `ceil(students / per_replica)`.
4. **TP vs replicas:** if the model fits one card → prefer many **TP=1** replicas (throughput + fault isolation). Use **TP=N** only when the model won't fit one card *or* you want a deep pooled KV cache for bursts. TP must stay within one node and divide attention-head count.
5. **CPU nodes** = `ceil(students / 16)` on `g6-dedicated-8`.

**Worked example — 80 students, Qwen3-8B-FP8:** weights ~8 GB, KV ~23 GB at 8K×~20 active → pooled budget → TP=4 on `g2-gpu-rtx4000a4-s`; 5 replicas for burst + fault isolation = **5 GPU nodes + 5 CPU nodes ≈ $17.80/hr**.

### Capacity-test (`make capacity-test`) — makes sizing empirical
Generalizes the existing `infra/manifests/load-test-job.yaml`.
- Deploys **1 GPU node + 1 vLLM replica** of the chosen model.
- A load Job ramps concurrency and records **p50/p99 latency, tokens/sec, KV saturation**, finds the concurrency where p99 crosses a threshold (default 10 s).
- **Profiles:** (a) generic agent-chat (default); (b) **workshop-aware** — replay the content repo's real example prompts, answering "GPUs for *this* workshop."
- Output feeds the wizard: real students-per-replica → exact replica/GPU count for the class.

---

## 4. Model catalog (ungated only)
| Tier | HF id | VRAM | Fits |
|---|---|---|---|
| Small | `Qwen/Qwen3-4B-Instruct-2507` | ~12 GB | 1× Ada 20 GB (cheap test) |
| Small | `openai/gpt-oss-20b` (MoE, MXFP4) | ~16 GB | 1× Ada 20 GB |
| Small | `Qwen/Qwen3-8B-FP8` **(default)** | ~18 GB | 1× Ada 20 GB, or TP=4 pool |
| Medium | `Qwen/Qwen3-14B-FP8` | ~28 GB | 2× Ada 40 GB / TP=2 |
| Medium | `Qwen/Qwen3-30B-A3B-Instruct-2507-FP8` (MoE) | ~36 GB | 40 GB pool — high class throughput |
| Medium | `mistralai/Mistral-Small-3.2-24B-Instruct-2506` | ~34 GB | 40 GB pool (vision-capable) |
| Large | `openai/gpt-oss-120b` (MoE, MXFP4) | ~80 GB | 4× Ada TP=4 / Blackwell |

Every model: cap `--max-model-len`, enable prefix caching (shared class system-prompt + tool schemas is a big KV win). Gated models (Llama 3.x) are intentionally **off** the menu; an advanced doc can show how to add one with a token.

---

## 5. Domain-optional design — single knob `domain`
| | No-domain (default) | Domain (opt-in) |
|---|---|---|
| DNS | `sslip.io`: `sNN.<lb-ip-dashed>.sslip.io` (dash form) | Linode DNS zone + records |
| TLS | self-signed wildcard `*.<lb-ip>.sslip.io` (one secret) | Let's Encrypt DNS-01 wildcard via lego |
| Token scope | k8s/Linodes/NodeBalancers | + Domains: Read/Write |
| Student UX | accept browser warning once, then WebSockets work | trusted cert, no warning |

- Secret name stays **`workshop-tls`** in both modes → Ingress + `generate-pods.sh` unchanged.
- TF: gate `data.linode_domain` + `linode_domain_record.*` on `count = domain == "" ? 0 : 1`; output `base_host`; create self-signed secret when no domain.
- `issue-cert.sh`: early-exit when `DOMAIN` empty. `generate-pods.sh`: feed it `terraform output -raw base_host` (already host-agnostic).
- Document the WebSocket gotcha: *open URL → accept warning once → log in.* Keep existing ingress timeouts (`proxy-read/send-timeout: 3600`, `force-ssl-redirect`).

---

## 5.5 Inference endpoint access

The vLLM endpoint stays **private** — that is the chosen security posture, not a gap.

- `vllm` Service is `ClusterIP`; NetworkPolicy `allow-workspaces-to-vllm` permits only
  `app: workspace` (+ `app: load-test`) pods → `vllm:8000`. No ingress route to vLLM.
  Students call `http://vllm:8000/v1` from inside their code-server.
- **Laptop / off-cluster access = `kubectl port-forward`** (tunnels via the API server, so
  the default-deny NetworkPolicy doesn't block it). Document this snippet in quickstart.md:
  ```bash
  export KUBECONFIG=infra/kubeconfig.yaml
  kubectl -n <namespace> port-forward svc/vllm 8000:8000
  # other terminal:
  curl http://localhost:8000/v1/models
  curl http://localhost:8000/v1/chat/completions -H 'Content-Type: application/json' \
    -d '{"model":"<model>","messages":[{"role":"user","content":"hi"}]}'
  ```
- **Non-goal (do NOT build):** a public `api.<host>` ingress route, an `--api-key`, or any
  internet-facing inference endpoint. Keeps the GPU endpoint off the public internet and
  removes the abuse/cost surface. If ever wanted later, it's an opt-in add — out of scope now.

---

## 6. Repo restructure

### Cut (duplicate teaching content; students clone it from the content repo, not here)
`workshop/` · `src/` · `docs/` (root) · `extend/` · `reference/` · root `Makefile` · root `requirements.txt`
→ replace with `examples/README.md` pointing at the default content repo + how to bring your own.

### Keep as core infra
`infra/terraform/*` · `infra/scripts/{provision,teardown,generate-pods,issue-cert,health-check,pre-warm,print-access-cards}.sh` · `infra/manifests/{namespace,networkpolicy,vllm-*,workspace-pod-template,secret.example}.yaml` · `infra/docs/{runbook,security,troubleshooting}.md`

### New
- `deploy.sh` / `Makefile` wizard (`deploy`, `teardown`, `capacity-test`)
- `infra/helm/` (or templated manifests) parameterizing: `model`, `tensor_parallel_size`, `replicas`, `namespace`, `image`, `student_count`
- generic `images/workspace/Dockerfile` (no content) + startup script that clones `content_repo` then `pip install -r requirements.txt`
- `infra/scripts/capacity-test.sh` + parametric load Job
- `infra/scripts/build-workspace-image.sh` (optional advanced)

### Proposed tree
```
akamai-workshop-platform/
  deploy.sh  Makefile  README.md  PLATFORM-PLAN.md
  config.example.yaml
  infra/
    terraform/{main,variables,outputs,versions}.tf + terraform.tfvars.example
    helm/values.yaml + templates/{namespace,vllm-statefulset,vllm-service,networkpolicy,secret,workspace-pod-template}.yaml
    scripts/{provision,teardown,generate-pods,issue-cert,capacity-test,health-check,pre-warm,print-access-cards,build-workspace-image}.sh
    images/workspace/{Dockerfile,startup.sh}
    docs/{quickstart,architecture,sizing,runbook,security,troubleshooting}.md
  examples/README.md            # pointer to default + bring-your-own content
```

### Couplings to parameterize (file:line)
**Must fix (blocks self-service):**
- `infra/manifests/vllm-statefulset.yaml:59` `--tensor-parallel-size=4` → value (must match GPU count of plan)
- `infra/manifests/vllm-statefulset.yaml:57` `--model=Qwen/Qwen3-8B-FP8` → value
- `infra/manifests/workspace-pod-template.yaml:17` image `ghcr.io/akamai-developers/...:latest` → flag
- `infra/scripts/issue-cert.sh:23` `DOMAIN=...burnersite.xyz` → `--domain` + no-domain early-exit
- `infra/scripts/generate-pods.sh:28-29` defaults `COUNT=80`, `HOST=...burnersite.xyz` → fix defaults/help
- namespace `workshop` hardcoded across `infra/manifests/*` + `provision.sh` → value
- `infra/manifests/load-test-job.yaml:51` model + `:42,57` `MAX_CONCURRENCY=80` → values (for capacity-test)

**Doc/config drift (fix while here):**
- `infra/manifests/vllm-statefulset.yaml:12` comment says **"TP=2 across 2-GPU nodes"** but arg is `--tensor-parallel-size=4` on 4-GPU nodes → comment is wrong.
- `infra/README.md:113` typo "~11s to ~11s" (missing TP=1 value).
- `infra/README.md` + `runbook.md` bake in "80 students", "s01–s80", `burnersite.xyz`, Stanford/Du'An timeline → genericize to "N students".
- Load-test p99 14s/42s numbers are repo lore, not committed measurements → re-measure via capacity-test, or mark unverified.

---

## 6.5 Region & GPU capacity handling

GPUs exist in only some Akamai regions, and even those go out of stock. The
wizard never hardcodes a region — it discovers and validates live.

**Two API signals (don't agree — verified 2026-06-05):**
- `GET /v4/regions` → filter `capabilities` for `"GPU Linodes"` = regions where GPU is *offered* (**21 of 33** today: us-ord, us-sea, us-east, us-lax, us-mia, us-southeast, + EU/Asia). This is the menu.
- `GET /v4/regions/availability` → live stock flag. Calibrated: `g6-standard`/`g6-dedicated` read `available=True`, but **every `g2-gpu`/`g1-gpu` combo reads `available=False`** in the regions this feed covers. GPU stock is genuinely constrained.
- **Ground truth = the provision attempt.** Capability = "offered"; availability feed is partial; only `terraform apply` succeeding proves stock. Plan for capacity errors.

**Wizard logic:**
1. Fetch GPU-capable regions live → present as the region menu (default = nearest US GPU region).
2. Cross-check the availability feed; de-prioritize flagged-unavailable plan/region combos.
3. **Provision the GPU pool FIRST (or run a capacity pre-check) before building the rest** — a capacity miss must cost ~nothing and never strand a half-built, billing cluster. (Today's `provision.sh` builds cluster + CPU + GPU together; reorder so GPU capacity is validated up front and failure is clean.)

**On a capacity failure, offer three fallbacks (in order):**
1. **Retry in another GPU region** from the live list.
2. **Drop to a smaller GPU plan** — an `a4` may be out while `a1` is in stock; re-plan as more TP=1 replicas (the §3 formula already supports this).
3. **Request capacity** — for large classes / Blackwell, Akamai may need a capacity request via the account team; print the exact plan + region + node count to ask for.

---

## 7. Build phases (each independently testable)
0. **Cleanup & reframe** — cut duplicate content → `examples/` pointer; fix doc drift; genericize README to "N students". *(Low risk, immediate clarity.)*
1. **Parameterize infra** — Helm/templated manifests: model, TP, replicas, namespace, image, student_count as values.
2. **Domain-optional + region/capacity** — sslip.io + self-signed default; gate DNS records; `issue-cert.sh` no-domain path; `base_host` output. **Live GPU-region discovery + capacity pre-flight (§6.5): provision GPU pool first, fail clean, fallbacks.**
3. **Generic image + clone-at-startup** — strip content from Dockerfile; `startup.sh` clones `content_repo` + installs deps; publish one public image; build becomes optional.
4. **The wizard** — collect inputs → catalog lookup → sizing formula → cost preview → confirm → write tfvars/values → provision + generate-pods → access cards. `deploy` / `teardown`.
5. **Capacity-test** — parametric load Job + `capacity-test.sh`; workshop-aware profile; wizard "measure before scale".
6. **Docs** — quickstart, architecture, sizing (with GPU decode), cost; genericize runbook.

Suggested order: 0 → 1 → 3 → 2 → 4 → 5 → 6 (cleanup first, then make the manifests parametric, then decouple the image, then domain modes, then the wizard ties it together, then capacity-test, then docs).
