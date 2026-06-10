#!/usr/bin/env python3
"""Sizing calculator for akamai-workshop-platform.

Turns "N students + this model" into a concrete plan: GPU node type + tensor
parallelism, replica/GPU-node count, CPU-node count, and an hourly cost estimate.
The wizard (deploy.sh) calls this; it is also runnable standalone.

    sizing.py plan --students 80 --model Qwen/Qwen3-8B-FP8
    sizing.py plan --students 80 --model Qwen/Qwen3-8B-FP8 --json
    sizing.py multi-plan --students 40 --models "Qwen/Qwen3-8B-FP8,Qwen/Qwen3-14B-FP8" --json
    sizing.py catalog
    sizing.py selftest          # asserts the PLATFORM-PLAN §3 worked example

Policy (kept deliberately simple — see infra/docs/sizing.md for the rationale):
  * One vLLM replica + one CPU node per ~16 students (burst headroom + fault
    isolation). Each replica spans all GPUs on its node via tensor parallelism.
  * GPU plan auto-pick: small classes (<=24) use the smallest plan that fits the
    model; larger classes use the repo-default 80 GB pool (g2-gpu-rtx4000a4-s,
    TP=4) when the model fits, escalating to Blackwell only when it must.
  * KV cache-aware: total VRAM = model weights + KV cache (based on model
    architecture, student concurrency, and context length) + framework overhead.
  * Stdlib only. Prices are $/hr verified against the Linode types API 2026-06-06
    (Blackwell is access-gated / unpublished, so its price is from PLATFORM-PLAN).

No HuggingFace token is ever required: the catalog is ungated-only.
"""

import argparse
import json
import math
import sys

# --- Model catalog (ungated only; vram_gb = approx weight footprint) ---
# Architecture params (num_layers, num_kv_heads, head_dim) are from HuggingFace
# config.json, verified 2026-06-08 for Qwen3-8B, Llama-3.1-8B, DeepSeek-R1-8B.
# kv_dtype_bytes=2 (FP16) for all models — vLLM uses FP16 KV cache by default.
# Per-model vLLM extra args. Only models that need special flags are listed here.
# The tool-call flags (--enable-auto-tool-choice --tool-call-parser=hermes) are safe
# for most models and applied by default. The reasoning parser is DeepSeek-only.
_DEEPSEEK_ARGS = ["--reasoning-parser=deepseek_r1", "--enable-auto-tool-choice", "--tool-call-parser=hermes"]
_TOOL_CALL_ARGS = ["--enable-auto-tool-choice", "--tool-call-parser=hermes"]
_GLM_ARGS = ["--enable-auto-tool-choice", "--tool-call-parser=glm47"]
# gpt-oss uses the harmony format, NOT hermes — the hermes tool parser crashes on it
# (Hermes2ProToolParser ... unexpected keyword 'token_ids'). vLLM ships a dedicated
# "openai" tool-call parser for gpt-oss. See docs.vllm.ai GPT-OSS recipe.
_GPTOSS_ARGS = ["--enable-auto-tool-choice", "--tool-call-parser=openai"]

MODEL_CATALOG = {
    "Qwen/Qwen3-4B-Instruct-2507":                   {"vram_gb": 12, "tier": "small",
        "num_layers": 36, "num_kv_heads": 4, "head_dim": 128, "kv_dtype_bytes": 2,
        "vllm_args": _TOOL_CALL_ARGS},
    "openai/gpt-oss-20b":                            {"vram_gb": 16, "tier": "small",
        "num_layers": 36, "num_kv_heads": 4, "head_dim": 128, "kv_dtype_bytes": 2,
        "vllm_args": _GPTOSS_ARGS},
    "Qwen/Qwen3-8B-FP8":                             {"vram_gb": 18, "tier": "small", "default": True,
        "num_layers": 36, "num_kv_heads": 8, "head_dim": 128, "kv_dtype_bytes": 2,
        "vllm_args": _TOOL_CALL_ARGS},
    "Qwen/Qwen3-14B-FP8":                            {"vram_gb": 28, "tier": "medium",
        "num_layers": 40, "num_kv_heads": 4, "head_dim": 128, "kv_dtype_bytes": 2,
        "vllm_args": _TOOL_CALL_ARGS},
    "Qwen/Qwen3-30B-A3B-Instruct-2507-FP8":         {"vram_gb": 36, "tier": "medium",
        "num_layers": 48, "num_kv_heads": 4, "head_dim": 128, "kv_dtype_bytes": 2,
        "vllm_args": _TOOL_CALL_ARGS},
    "mistralai/Mistral-Small-3.2-24B-Instruct-2506": {"vram_gb": 34, "tier": "medium",
        "num_layers": 40, "num_kv_heads": 8, "head_dim": 128, "kv_dtype_bytes": 2,
        "vllm_args": _TOOL_CALL_ARGS},
    "openai/gpt-oss-120b":                           {"vram_gb": 80, "tier": "large",
        "num_layers": 80, "num_kv_heads": 8, "head_dim": 128, "kv_dtype_bytes": 2,
        "vllm_args": _GPTOSS_ARGS},
    "NousResearch/Meta-Llama-3.1-8B-Instruct":       {"vram_gb": 20, "tier": "small",
        "num_layers": 32, "num_kv_heads": 8, "head_dim": 128, "kv_dtype_bytes": 2,
        "vllm_args": _TOOL_CALL_ARGS,
        "note": "llama3.1:8b (ungated mirror of the gated Meta repo)"},
    "deepseek-ai/DeepSeek-R1-0528-Qwen3-8B":         {"vram_gb": 22, "tier": "small",
        "num_layers": 36, "num_kv_heads": 8, "head_dim": 128, "kv_dtype_bytes": 2,
        "vllm_args": _DEEPSEEK_ARGS,
        "note": "deepseek-r1:8b reasoning model (Qwen3-8B base)"},
    "Qwen/Qwen3.6-27B-FP8":                          {"vram_gb": 32, "tier": "medium",
        "num_layers": 36, "num_kv_heads": 4, "head_dim": 128, "kv_dtype_bytes": 2,
        "vllm_args": _TOOL_CALL_ARGS,
        "note": "qwen3.6:27b dense FP8, multimodal (vision)"},
    "Qwen/Qwen3.6-35B-A3B-FP8":                      {"vram_gb": 38, "tier": "large",
        "num_layers": 48, "num_kv_heads": 4, "head_dim": 128, "kv_dtype_bytes": 2,
        "vllm_args": _TOOL_CALL_ARGS,
        "note": "qwen3.6:35b MoE FP8, multimodal (vision)"},
    "RedHatAI/DeepSeek-R1-Distill-Llama-70B-FP8-dynamic": {"vram_gb": 73, "tier": "large",
        "num_layers": 80, "num_kv_heads": 8, "head_dim": 128, "kv_dtype_bytes": 2,
        "vllm_args": _DEEPSEEK_ARGS,
        "note": "deepseek-r1:70b FP8; needs the 96GB Blackwell GPU plan"},
    "google/gemma-4-12b-it":                              {"vram_gb": 24, "tier": "medium",
        "num_layers": 48, "num_kv_heads": 4, "head_dim": 256, "kv_dtype_bytes": 2,
        "vllm_args": _TOOL_CALL_ARGS,
        "note": "multimodal (text/image/audio), 256K context, Apache 2.0"},
    "microsoft/phi-4":                                    {"vram_gb": 28, "tier": "medium",
        "num_layers": 40, "num_kv_heads": 10, "head_dim": 128, "kv_dtype_bytes": 2,
        "vllm_args": _TOOL_CALL_ARGS,
        "note": "strong reasoning, MIT license"},
    "ibm-granite/granite-3.3-8b-instruct":                {"vram_gb": 16, "tier": "small",
        "num_layers": 32, "num_kv_heads": 8, "head_dim": 128, "kv_dtype_bytes": 2,
        "vllm_args": _TOOL_CALL_ARGS,
        "note": "128K context, 12 languages, Apache 2.0"},
    "Qwen/Qwen2.5-Coder-14B-Instruct":                   {"vram_gb": 28, "tier": "medium",
        "num_layers": 48, "num_kv_heads": 4, "head_dim": 128, "kv_dtype_bytes": 2,
        "vllm_args": _TOOL_CALL_ARGS,
        "note": "top open coding model, Apache 2.0"},
    "zai-org/GLM-4.7-Flash":                              {"vram_gb": 36, "tier": "medium",
        "num_layers": 40, "num_kv_heads": 4, "head_dim": 128, "kv_dtype_bytes": 2,
        "vllm_args": _GLM_ARGS,
        "note": "#1 function-calling model, MoE 31B/3B active, MIT license"},
}

DEFAULT_MODEL = "Qwen/Qwen3-8B-FP8"

# --- GPU plans (smallest pool first). hourly verified vs Linode types API 2026-06-06. ---
GPU_PLANS = [
    {"id": "g2-gpu-rtx4000a1-s",                  "gpus": 1, "vram_gb": 20, "hourly": 0.52},
    {"id": "g2-gpu-rtx4000a2-s",                  "gpus": 2, "vram_gb": 40, "hourly": 1.05},
    {"id": "g2-gpu-rtx4000a4-s",                  "gpus": 4, "vram_gb": 80, "hourly": 2.96},
    {"id": "g3-gpu-rtxpro6000-blackwell-1",       "gpus": 1, "vram_gb": 96, "hourly": 2.50, "gated": True},
]
GPU_BY_ID = {p["id"]: p for p in GPU_PLANS}

CPU_PLAN = {"id": "g6-dedicated-8", "hourly": 0.216}

# One replica + one CPU node per this many students (burst headroom + fault isolation).
STUDENTS_PER_NODE = 16
# At or below this size, prefer the cheapest plan that fits over the pooled default.
SMALL_CLASS_MAX = 24
# Framework overhead (CUDA contexts, weight loader, scheduling) in GB.
FRAMEWORK_OVERHEAD_GB = 1.5
# KV cache sizing uses a realistic average context length (not the vLLM max).
# Workshop students rarely exceed 4k tokens in a single conversation turn.
KV_SIZING_CONTEXT_LEN = 4096
CONCURRENCY_RATIO = 0.3
MIN_ACTIVE_SLOTS = 4


def slugify(name):
    """Convert a model name to a k8s-safe slug (lowercase, max 40 chars)."""
    import re
    s = name.lower()
    s = re.sub(r"[^a-z0-9]+", "-", s)
    s = s.strip("-")
    return s[:40]


def kv_cache_gb(model, students, context_len=KV_SIZING_CONTEXT_LEN):
    """Estimate KV cache memory in GB for a model given student concurrency."""
    m = MODEL_CATALOG[model]
    kv_per_token = 2 * m["num_kv_heads"] * m["head_dim"] * m["kv_dtype_bytes"]
    kv_per_token_all_layers = kv_per_token * m["num_layers"]
    concurrent = max(math.ceil(students * CONCURRENCY_RATIO), MIN_ACTIVE_SLOTS)
    return (kv_per_token_all_layers * context_len * concurrent) / (1024 ** 3)


def _total_vram_needed(model, students):
    """Total VRAM = weights + KV cache + framework overhead."""
    model_vram = MODEL_CATALOG[model]["vram_gb"]
    kv = kv_cache_gb(model, students)
    return model_vram + kv + FRAMEWORK_OVERHEAD_GB


def _pick_gpu_plan(students, model):
    """Choose the GPU plan + tensor-parallel size for this class + model."""
    needed = _total_vram_needed(model, students)
    usable_fraction = 0.9  # gpu_memory_utilization default
    if students <= SMALL_CLASS_MAX:
        for plan in GPU_PLANS:
            if plan["vram_gb"] * usable_fraction >= needed:
                return plan
        raise ValueError(
            f"model needs ~{needed:.0f} GB but no GPU plan is large enough"
        )
    for plan in GPU_PLANS:
        if plan["id"] == "g2-gpu-rtx4000a4-s" and plan["vram_gb"] * usable_fraction >= needed:
            return plan
    for plan in GPU_PLANS:
        if plan["vram_gb"] * usable_fraction >= needed:
            return plan
    raise ValueError(f"model needs ~{needed:.0f} GB but no GPU plan is large enough")


def size(students, model=DEFAULT_MODEL, gpu_node_type=None,
         tensor_parallel_size=None, cpu_node_type=None):
    """Return a sizing plan dict. Explicit gpu_node_type / tensor_parallel_size
    override the autopilot (used by the headless e2e smoke test)."""
    if students < 1:
        raise ValueError("students must be >= 1")
    if model not in MODEL_CATALOG:
        raise ValueError(
            f"unknown model '{model}'. Known ungated models:\n  "
            + "\n  ".join(MODEL_CATALOG)
        )

    model_vram = MODEL_CATALOG[model]["vram_gb"]
    kv_gb = round(kv_cache_gb(model, students), 2)

    if gpu_node_type:
        if gpu_node_type not in GPU_BY_ID:
            raise ValueError(
                f"unknown gpu_node_type '{gpu_node_type}'. Known: "
                + ", ".join(GPU_BY_ID)
            )
        plan = GPU_BY_ID[gpu_node_type]
    else:
        plan = _pick_gpu_plan(students, model)

    tp = tensor_parallel_size if tensor_parallel_size else plan["gpus"]
    if tp != plan["gpus"]:
        raise ValueError(
            f"tensor_parallel_size={tp} must equal the GPU count of "
            f"{plan['id']} ({plan['gpus']})"
        )

    replicas = max(1, math.ceil(students / STUDENTS_PER_NODE))
    gpu_node_count = replicas
    cpu = CPU_BY_ID(cpu_node_type) if cpu_node_type else CPU_PLAN
    cpu_node_count = max(1, math.ceil(students / STUDENTS_PER_NODE))

    gpu_cost = gpu_node_count * plan["hourly"]
    cpu_cost = cpu_node_count * cpu["hourly"]
    hourly = round(gpu_cost + cpu_cost, 2)

    return {
        "students": students,
        "model": model,
        "model_slug": slugify(model),
        "model_vram_gb": model_vram,
        "kv_cache_gb": kv_gb,
        "total_vram_gb": round(model_vram + kv_gb + FRAMEWORK_OVERHEAD_GB, 1),
        "gpu_node_type": plan["id"],
        "gpu_node_count": gpu_node_count,
        "gpu_vram_pool_gb": plan["vram_gb"],
        "tensor_parallel_size": tp,
        "replicas": replicas,
        "cpu_node_type": cpu["id"],
        "cpu_node_count": cpu_node_count,
        "gpu_gated": plan.get("gated", False),
        "vllm_args": MODEL_CATALOG[model].get("vllm_args", []),
        "hourly_usd": hourly,
        "gpu_hourly_usd": round(gpu_cost, 2),
        "cpu_hourly_usd": round(cpu_cost, 2),
        "cost_4h_usd": round(hourly * 4, 2),
    }


def CPU_BY_ID(cid):
    if cid == CPU_PLAN["id"]:
        return CPU_PLAN
    # Unknown CPU plan: price unknown, fall back to default plan's price but keep id.
    return {"id": cid, "hourly": CPU_PLAN["hourly"]}


def format_plan(p):
    g = " (ACCESS-GATED — may not provision)" if p["gpu_gated"] else ""
    return (
        f"Model {p['model']}  ·  ~{p['model_vram_gb']} GB weights  ·  ungated\n"
        f"VRAM: {p['model_vram_gb']} GB weights + {p['kv_cache_gb']} GB KV cache + "
        f"{FRAMEWORK_OVERHEAD_GB} GB overhead = ~{p['total_vram_gb']} GB total\n"
        f"{p['students']} students  →  {p['replicas']} vLLM replica(s)  ·  "
        f"{p['gpu_node_count']}× {p['gpu_node_type']} "
        f"(TP={p['tensor_parallel_size']}, {p['gpu_vram_pool_gb']} GB pool each){g}\n"
        f"                {p['cpu_node_count']}× {p['cpu_node_type']} CPU node(s) "
        f"(code-servers)\n"
        f"Est. cost: ~${p['hourly_usd']}/hr  "
        f"(GPU ${p['gpu_hourly_usd']} + CPU ${p['cpu_hourly_usd']})  ·  "
        f"~${p['cost_4h_usd']} for a 4-hour class"
    )


def cmd_plan(args):
    p = size(
        students=args.students,
        model=args.model,
        gpu_node_type=args.gpu_node_type,
        tensor_parallel_size=args.tp,
        cpu_node_type=args.cpu_node_type,
    )
    if args.json:
        print(json.dumps(p, indent=2))
    else:
        print(format_plan(p))


def cmd_multi_plan(args):
    """Compute sizing plans for multiple models and aggregate costs."""
    models = [m.strip() for m in args.models.split(",") if m.strip()]
    if len(models) < 2:
        print("ERROR: multi-plan requires at least 2 comma-separated models",
              file=sys.stderr)
        sys.exit(2)
    plans = []
    for model in models:
        p = size(students=args.students, model=model)
        p["gpu_pool_label"] = f"gpu-{slugify(model)}"
        plans.append(p)
    # CPU nodes are shared across models — use the single-model formula.
    cpu_node_count = max(1, math.ceil(args.students / STUDENTS_PER_NODE))
    cpu_cost = cpu_node_count * CPU_PLAN["hourly"]
    gpu_cost = sum(p["gpu_hourly_usd"] for p in plans)
    hourly = round(gpu_cost + cpu_cost, 2)
    result = {
        "students": args.students,
        "multi_model": True,
        "models": plans,
        "cpu_node_type": CPU_PLAN["id"],
        "cpu_node_count": cpu_node_count,
        "gpu_hourly_usd": round(gpu_cost, 2),
        "cpu_hourly_usd": round(cpu_cost, 2),
        "hourly_usd": hourly,
        "cost_4h_usd": round(hourly * 4, 2),
    }
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        for p in plans:
            print(format_plan(p))
            print()
        print(f"Agentgateway: routes by model field → {len(plans)} vLLM backends")
        print(f"Total est. cost: ~${hourly}/hr  "
              f"(GPU ${result['gpu_hourly_usd']} + CPU ${result['cpu_hourly_usd']})  ·  "
              f"~${result['cost_4h_usd']} for a 4-hour class")


def cmd_catalog(_args):
    print("Ungated model catalog (no HuggingFace token required):\n")
    for mid, m in MODEL_CATALOG.items():
        tag = " (default)" if m.get("default") else ""
        print(f"  {mid:50} ~{m['vram_gb']:>3} GB  [{m['tier']:6}]{tag}")
        if m.get("note"):
            print(f"  {'':52}{m['note']}")


def _grouped_models():
    """Return models in display order: small, medium, large."""
    tiers = ["small", "medium", "large"]
    grouped = {t: [] for t in tiers}
    for mid, m in MODEL_CATALOG.items():
        grouped[m["tier"]].append((mid, m))
    result = []
    for t in tiers:
        result.extend(grouped[t])
    return result


def cmd_numbered_catalog(_args):
    """Print a numbered list for the wizard's interactive picker (tab-delimited)."""
    for i, (mid, m) in enumerate(_grouped_models(), 1):
        tag = " *" if m.get("default") else ""
        note = f"  {m['note']}" if m.get("note") else ""
        print(f"{i}\t{mid}\t~{m['vram_gb']} GB\t{m['tier']}{tag}{note}")


def cmd_wizard_table(_args):
    """Print a formatted, colored table for the deploy wizard."""
    use_color = sys.stdout.isatty()
    if use_color:
        B = "\033[1m"; D = "\033[2m"; R = "\033[0m"
        GR = "\033[32m"; YE = "\033[33m"; RE = "\033[31m"; CY = "\033[36m"
    else:
        B = D = R = GR = YE = RE = CY = ""

    tier_colors = {"small": GR, "medium": YE, "large": RE}
    tier_gpus = {"small": "1-2 GPUs", "medium": "2-4 GPUs", "large": "4+ GPUs"}

    # Group by tier, preserving catalog order within each tier
    tiers_order = ["small", "medium", "large"]
    grouped = {t: [] for t in tiers_order}
    for mid, m in MODEL_CATALOG.items():
        grouped[m["tier"]].append((mid, m))

    # Assign sequential numbers across the grouped display order
    display_order = []
    for tier in tiers_order:
        display_order.extend(grouped[tier])

    default_num = 1
    for i, (mid, m) in enumerate(display_order, 1):
        if m.get("default"):
            default_num = i

    # Print table
    num = 0
    for tier in tiers_order:
        items = grouped[tier]
        if not items:
            continue
        tc = tier_colors[tier]
        print(f"        {tc}{B}{tier.upper()}{R} {D}{tier_gpus[tier]}{R}")
        print(f"        {D}{'─' * 68}{R}")
        for mid, m in items:
            num += 1
            is_def = m.get("default", False)
            nc = GR if is_def else CY
            star = "*" if is_def else " "
            label = "default" if is_def else ""
            display_name = mid if len(mid) <= 44 else mid[:41] + "..."
            print(f"        {nc}{B}{num:>2}{R}{nc}{star}{R}  {display_name:<44}  {D}{m['vram_gb']:>3} GB{R}  {tc}{label}{R}")
        print()

    print(f"        {D}* = default    Enter one number or comma-separate for multi-model{R}")
    print(f"__DEFAULT__:{default_num}")


def cmd_selftest(_args):
    """Assert the PLATFORM-PLAN §3 worked example structurally."""
    p = size(students=80, model="Qwen/Qwen3-8B-FP8")
    checks = [
        ("gpu_node_type", p["gpu_node_type"], "g2-gpu-rtx4000a4-s"),
        ("gpu_node_count", p["gpu_node_count"], 5),
        ("tensor_parallel_size", p["tensor_parallel_size"], 4),
        ("cpu_node_count", p["cpu_node_count"], 5),
        ("replicas", p["replicas"], 5),
    ]
    ok = True
    for name, got, want in checks:
        status = "ok" if got == want else "FAIL"
        if got != want:
            ok = False
        print(f"  [{status}] {name}: {got} (want {want})")
    # Cost is accurate to live prices; the plan's rounded ~$17.80 assumed a pricier
    # CPU node. Assert it's in a sane band rather than an exact figure.
    cost_ok = 14.0 <= p["hourly_usd"] <= 20.0
    print(f"  [{'ok' if cost_ok else 'FAIL'}] hourly_usd: ${p['hourly_usd']} (expect $14–20)")
    ok = ok and cost_ok

    # KV cache sanity: must be present and positive.
    kv_ok = p["kv_cache_gb"] > 0 and p["total_vram_gb"] > p["model_vram_gb"]
    print(f"  [{'ok' if kv_ok else 'FAIL'}] kv_cache_gb: {p['kv_cache_gb']} "
          f"(total VRAM: {p['total_vram_gb']} GB)")
    ok = ok and kv_ok

    # Slug generation.
    slug_ok = p["model_slug"] == "qwen-qwen3-8b-fp8"
    print(f"  [{'ok' if slug_ok else 'FAIL'}] model_slug: {p['model_slug']} "
          f"(want qwen-qwen3-8b-fp8)")
    ok = ok and slug_ok

    # Small/cheap footprint (e2e smoke) sanity.
    e2e = size(students=1, model="Qwen/Qwen3-4B-Instruct-2507",
               gpu_node_type="g2-gpu-rtx4000a1-s", tensor_parallel_size=1)
    e2e_ok = (e2e["gpu_node_count"] == 1 and e2e["cpu_node_count"] == 1
              and e2e["tensor_parallel_size"] == 1)
    print(f"  [{'ok' if e2e_ok else 'FAIL'}] e2e footprint: "
          f"{e2e['gpu_node_count']} GPU / {e2e['cpu_node_count']} CPU node")
    ok = ok and e2e_ok

    # Multi-model: two-model plan produces valid aggregate.
    m1 = size(students=40, model="Qwen/Qwen3-8B-FP8")
    m2 = size(students=40, model="Qwen/Qwen3-14B-FP8")
    multi_ok = (m1["model_slug"] != m2["model_slug"]
                and m1["kv_cache_gb"] > 0 and m2["kv_cache_gb"] > 0)
    agg_gpu = round(m1["gpu_hourly_usd"] + m2["gpu_hourly_usd"], 2)
    print(f"  [{'ok' if multi_ok else 'FAIL'}] multi-model: "
          f"2 models, aggregate GPU cost ${agg_gpu}/hr")
    ok = ok and multi_ok

    print("\nSELF-TEST", "PASSED" if ok else "FAILED")
    sys.exit(0 if ok else 1)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    pl = sub.add_parser("plan", help="compute a sizing plan")
    pl.add_argument("--students", type=int, required=True)
    pl.add_argument("--model", default=DEFAULT_MODEL)
    pl.add_argument("--gpu-node-type", default=None,
                    help="override autopilot GPU plan (must match a known plan)")
    pl.add_argument("--tp", type=int, default=None,
                    help="override tensor-parallel size (must equal plan GPU count)")
    pl.add_argument("--cpu-node-type", default=None)
    pl.add_argument("--json", action="store_true")
    pl.set_defaults(func=cmd_plan)

    mp = sub.add_parser("multi-plan", help="compute per-model plans for multiple models")
    mp.add_argument("--students", type=int, required=True)
    mp.add_argument("--models", required=True,
                    help="comma-separated model names")
    mp.add_argument("--json", action="store_true")
    mp.set_defaults(func=cmd_multi_plan)

    cat = sub.add_parser("catalog", help="list the ungated model catalog")
    cat.set_defaults(func=cmd_catalog)

    ncat = sub.add_parser("numbered-catalog", help="numbered list for interactive wizard")
    ncat.set_defaults(func=cmd_numbered_catalog)

    wtab = sub.add_parser("wizard-table", help="formatted table for deploy wizard")
    wtab.set_defaults(func=cmd_wizard_table)

    st = sub.add_parser("selftest", help="assert the worked example")
    st.set_defaults(func=cmd_selftest)

    args = ap.parse_args()
    try:
        args.func(args)
    except ValueError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
