#!/usr/bin/env python3
"""Sizing calculator for akamai-workshop-platform.

Turns "N students + this model" into a concrete plan: GPU node type + tensor
parallelism, replica/GPU-node count, CPU-node count, and an hourly cost estimate.
The wizard (deploy.sh) calls this; it is also runnable standalone.

    sizing.py plan --students 80 --model Qwen/Qwen3-8B-FP8
    sizing.py plan --students 80 --model Qwen/Qwen3-8B-FP8 --json
    sizing.py catalog
    sizing.py selftest          # asserts the PLATFORM-PLAN §3 worked example

Policy (kept deliberately simple — see infra/docs/sizing.md for the rationale):
  * One vLLM replica + one CPU node per ~16 students (burst headroom + fault
    isolation). Each replica spans all GPUs on its node via tensor parallelism.
  * GPU plan auto-pick: small classes (<=24) use the smallest plan that fits the
    model; larger classes use the repo-default 80 GB pool (g2-gpu-rtx4000a4-s,
    TP=4) when the model fits, escalating to Blackwell only when it must.
  * Stdlib only. Prices are $/hr verified against the Linode types API 2026-06-06
    (Blackwell is access-gated / unpublished, so its price is from PLATFORM-PLAN).

No HuggingFace token is ever required: the catalog is ungated-only.
"""

import argparse
import json
import math
import sys

# --- Model catalog (ungated only; vram_gb = approx served footprint, weights+overhead) ---
MODEL_CATALOG = {
    "Qwen/Qwen3-4B-Instruct-2507":                   {"vram_gb": 12, "tier": "small"},
    "openai/gpt-oss-20b":                            {"vram_gb": 16, "tier": "small"},
    "Qwen/Qwen3-8B-FP8":                             {"vram_gb": 18, "tier": "small", "default": True},
    "Qwen/Qwen3-14B-FP8":                            {"vram_gb": 28, "tier": "medium"},
    "Qwen/Qwen3-30B-A3B-Instruct-2507-FP8":         {"vram_gb": 36, "tier": "medium"},
    "mistralai/Mistral-Small-3.2-24B-Instruct-2506": {"vram_gb": 34, "tier": "medium"},
    "openai/gpt-oss-120b":                           {"vram_gb": 80, "tier": "large"},
    # --- Added from Ollama-tag requests. Tags map to vLLM-servable HF repos;
    #     all verified UNGATED via the HF API on 2026-06-06 (no HF token needed). ---
    # llama3.1:8b — official meta-llama/Llama-3.1-8B-Instruct is gated; this is the
    # ungated BF16 mirror that loads identically in vLLM (Llama 3.1 Community License).
    "NousResearch/Meta-Llama-3.1-8B-Instruct":       {"vram_gb": 20, "tier": "small",
        "note": "llama3.1:8b (ungated mirror of the gated Meta repo)"},
    # deepseek-r1:8b — the current Ollama default is R1-0528 distilled onto Qwen3-8B
    # (qwen3 arch, already supported here). Reasoning model: cap --max-model-len, temp ~0.6.
    "deepseek-ai/DeepSeek-R1-0528-Qwen3-8B":         {"vram_gb": 22, "tier": "small",
        "note": "deepseek-r1:8b reasoning model (Qwen3-8B base)"},
    # NOTE: gemma4:26b and gemma4:12b are intentionally NOT here. Both Gemma 4 archs
    # (Gemma4ForConditionalGeneration / Gemma4UnifiedForConditionalGeneration) require a
    # vLLM nightly per the official vLLM Gemma 4 recipe; the pinned vllm-openai:v0.20.2
    # does not support them. Add them once infra/helm/values.yaml pins a compatible image.
    # qwen3.6:27b — dense 27B, multimodal (vision-language). qwen3_5 arch (vLLM >= 0.17).
    "Qwen/Qwen3.6-27B-FP8":                          {"vram_gb": 32, "tier": "medium",
        "note": "qwen3.6:27b dense FP8, multimodal (vision)"},
    # qwen3.6:35b — 35B-A3B MoE, multimodal (vision-language). qwen3_5_moe arch (vLLM >= 0.17).
    "Qwen/Qwen3.6-35B-A3B-FP8":                      {"vram_gb": 38, "tier": "large",
        "note": "qwen3.6:35b MoE FP8, multimodal (vision)"},
    # deepseek-r1:70b-llama-distill — ungated FP8. ~73 GB weights, so it only fits the
    # 96 GB Blackwell plan (access-gated, limited availability); the wizard will warn.
    "RedHatAI/DeepSeek-R1-Distill-Llama-70B-FP8-dynamic": {"vram_gb": 73, "tier": "large",
        "note": "deepseek-r1:70b FP8; needs the 96GB Blackwell GPU plan"},
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
# KV cache + framework overhead headroom multiplier on top of raw weights.
VRAM_HEADROOM = 1.25


def _pick_gpu_plan(students, model_vram):
    """Choose the GPU plan + tensor-parallel size for this class + model."""
    needed = model_vram * VRAM_HEADROOM
    if students <= SMALL_CLASS_MAX:
        # Cheapest plan whose pooled VRAM holds the model.
        for plan in GPU_PLANS:
            if plan["vram_gb"] >= needed:
                return plan
        raise ValueError(
            f"model needs ~{needed:.0f} GB but no GPU plan is large enough"
        )
    # Full class: repo default is the 80 GB pool (a4-s, TP=4) when the model fits;
    # escalate to Blackwell only when the model won't fit 80 GB.
    for plan in GPU_PLANS:
        if plan["id"] == "g2-gpu-rtx4000a4-s" and plan["vram_gb"] >= needed:
            return plan
    for plan in GPU_PLANS:
        if plan["vram_gb"] >= needed:
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

    if gpu_node_type:
        if gpu_node_type not in GPU_BY_ID:
            raise ValueError(
                f"unknown gpu_node_type '{gpu_node_type}'. Known: "
                + ", ".join(GPU_BY_ID)
            )
        plan = GPU_BY_ID[gpu_node_type]
    else:
        plan = _pick_gpu_plan(students, model_vram)

    tp = tensor_parallel_size if tensor_parallel_size else plan["gpus"]
    if tp != plan["gpus"]:
        raise ValueError(
            f"tensor_parallel_size={tp} must equal the GPU count of "
            f"{plan['id']} ({plan['gpus']})"
        )

    replicas = max(1, math.ceil(students / STUDENTS_PER_NODE))
    gpu_node_count = replicas  # one replica per node; TP pools the node's GPUs
    cpu = CPU_BY_ID(cpu_node_type) if cpu_node_type else CPU_PLAN
    cpu_node_count = max(1, math.ceil(students / STUDENTS_PER_NODE))

    gpu_cost = gpu_node_count * plan["hourly"]
    cpu_cost = cpu_node_count * cpu["hourly"]
    hourly = round(gpu_cost + cpu_cost, 2)

    return {
        "students": students,
        "model": model,
        "model_vram_gb": model_vram,
        "gpu_node_type": plan["id"],
        "gpu_node_count": gpu_node_count,
        "gpu_vram_pool_gb": plan["vram_gb"],
        "tensor_parallel_size": tp,
        "replicas": replicas,
        "cpu_node_type": cpu["id"],
        "cpu_node_count": cpu_node_count,
        "gpu_gated": plan.get("gated", False),
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
        f"Model {p['model']}  ·  ~{p['model_vram_gb']} GB  ·  ungated\n"
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


def cmd_catalog(_args):
    print("Ungated model catalog (no HuggingFace token required):\n")
    for mid, m in MODEL_CATALOG.items():
        tag = " (default)" if m.get("default") else ""
        print(f"  {mid:50} ~{m['vram_gb']:>3} GB  [{m['tier']:6}]{tag}")
        if m.get("note"):
            print(f"  {'':52}{m['note']}")


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
    # Small/cheap footprint (e2e smoke) sanity.
    e2e = size(students=1, model="Qwen/Qwen3-4B-Instruct-2507",
               gpu_node_type="g2-gpu-rtx4000a1-s", tensor_parallel_size=1)
    e2e_ok = (e2e["gpu_node_count"] == 1 and e2e["cpu_node_count"] == 1
              and e2e["tensor_parallel_size"] == 1)
    print(f"  [{'ok' if e2e_ok else 'FAIL'}] e2e footprint: "
          f"{e2e['gpu_node_count']} GPU / {e2e['cpu_node_count']} CPU node")
    ok = ok and e2e_ok
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

    cat = sub.add_parser("catalog", help="list the ungated model catalog")
    cat.set_defaults(func=cmd_catalog)

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
