# Cost

GPU nodes bill **by the hour** (effective 2026-07-01, GPU Linodes are hourly-only, no
monthly cap). The wizard prints an estimate before you confirm; this doc shows how it's
computed and how to keep the bill down.

## What you pay for

| Resource | Plan (default) | $/hr |
|---|---|---|
| GPU node (vLLM replica) | `g2-gpu-rtx4000a4-s` (4× RTX 4000 Ada, 80 GB) | $2.96 |
| CPU node (code-servers) | `g6-dedicated-8` | $0.216 |
| NodeBalancer (ingress) | 1× | ~$0.015 |
| Block storage (model PVCs) | per replica | small |
| Object Storage (`object_storage: managed`) | 1 bucket + 1 scoped key / student | trivial |

`object_storage: managed` storage spend itself is negligible, but it provisions **one
bucket per student** (keys scope to buckets, not prefixes — see [security.md](security.md)).
At ~200 students that can exceed the default account bucket-count limit: **raise it via a
support ticket ahead of the event**. Teardown revokes the keys and empties+deletes the
buckets, but they survive `terraform destroy`, so confirm none linger afterward.

Prices verified against the Linode types API on 2026-06-06. Per-card / smaller plans:
`g2-gpu-rtx4000a1-s` (1 GPU, 20 GB) $0.52 · `g2-gpu-rtx4000a2-s` (2 GPU, 40 GB) $1.05.
See [sizing.md](sizing.md) for the full table and the GPU plan-name decode.

## The estimate

```
hourly = gpu_node_count × gpu_$/hr  +  cpu_node_count × cpu_$/hr
```

The wizard computes node counts from student count + model (one vLLM replica + one CPU
node per ~16 students). Print any plan's cost without deploying:

```bash
python3 infra/scripts/sizing.py plan --students 80 --model Qwen/Qwen3-8B-FP8
# or the JSON the wizard consumes:
python3 infra/scripts/sizing.py plan --students 80 --model Qwen/Qwen3-8B-FP8 --json
```

## Worked example — 80 students, Qwen3-8B-FP8

| | count | $/hr each | subtotal |
|---|---|---|---|
| GPU `g2-gpu-rtx4000a4-s` | 5 | $2.96 | $14.80 |
| CPU `g6-dedicated-8` | 5 | $0.216 | $1.08 |
| **Total** | | | **~$15.88/hr** |

≈ **$64 for a 4-hour class**. (PLATFORM-PLAN §3 rounds this to ~$17.80 using an older,
higher CPU-node price; the figure above uses live prices.)

The cheapest footprint — the e2e smoke / capacity-probe box (1× `g2-gpu-rtx4000a1-s` +
1 CPU node) — is **~$0.74/hr**.

## Keeping the bill down

- **Tear down when class ends.** `make teardown`. This is the single biggest lever — a
  forgotten 80-student cluster is ~$15.88 every hour. Verify with `linode-cli lke clusters-list`.
- **Measure before you scale.** `make capacity-test` finds the real students-per-replica for
  your model + content, which often means fewer GPU nodes than the conservative default.
- **Right-size the model.** A smaller ungated model (e.g. `Qwen/Qwen3-4B-Instruct-2507`)
  fits a single 20 GB card, so small classes can run on `g2-gpu-rtx4000a1-s` at $0.52/hr.
- **Provision close to class time.** Cold start (cluster + GPU operator + model download)
  is ~15–20 min; you don't need the cluster live hours early.
