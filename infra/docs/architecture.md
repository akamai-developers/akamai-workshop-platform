# Architecture

`akamai-workshop-platform` provisions a per-classroom stack on Akamai LKE. Everything
is driven by **values** — there are no hardcoded model names, student counts, or domains
in the manifests.

## Layers

```
deploy.sh (wizard)  ──►  terraform.tfvars  +  infra/helm/values.yaml
        │
        ├─ terraform apply ──► LKE cluster
        │                        ├─ CPU node pool      (g6-dedicated-8 × N → workspaces)
        │                        ├─ GPU node pool      (g2-gpu-* × M, label pool=gpu → vLLM)
        │                        ├─ gpu-operator        (NVIDIA drivers + device plugin)
        │                        ├─ cloud-firewall      (per-node worker firewall)
        │                        ├─ ingress-nginx        (+ NodeBalancer public IP)
        │                        └─ DNS records          (domain mode only)
        │
        ├─ helm template infra/helm | kubectl apply ──► shared cluster resources
        │                        ├─ Namespace            (PSS baseline)
        │                        ├─ NetworkPolicies      (default-deny + 2 allows)
        │                        ├─ vLLM Service          (ClusterIP, internal only)
        │                        └─ vLLM StatefulSet      (model, TP, replicas = values)
        │
        └─ generate-pods.sh ──► per-student workspaces
                                 ├─ Pod ws-NN            (code-server, clones content_repo)
                                 ├─ Service ws-NN
                                 ├─ Secret ws-NN-password
                                 └─ Ingress (sNN.<base-host>)  + access-cards.csv
```

## What is a value vs. what is generated

| Concern | Where it lives | Parameterized by |
|---|---|---|
| Cluster region, k8s version, node types/counts, label, domain | `infra/terraform/` | `terraform.tfvars` |
| Namespace, vLLM model, tensor-parallel size, replicas, image, max-model-len, gpu-memory-util | `infra/helm/values.yaml` | `--set` / values file |
| Per-student workspaces (image, model, vLLM host, content repo, namespace) | `infra/scripts/generate-pods.sh` + `infra/manifests/workspace-pod-template.yaml` | flags / env |

## The Helm chart (`infra/helm/`)

A minimal chart that renders only the **shared** cluster resources. It is applied with
`helm template … | kubectl apply -f -` (no Tiller, no release state on the cluster).
Per-student workspaces are intentionally *not* in the chart — `generate-pods.sh` owns them
because it must preserve student passwords idempotently across re-runs, which a stateless
template render cannot do.

Flat value names match the wizard and `--set` ergonomics:

```bash
helm template awp infra/helm \
  --set model=Qwen/Qwen3-4B-Instruct-2507 \
  --set tensor_parallel_size=1 \
  --set replicas=1 \
  --set namespace=awp-e2e-smoke
```

Key values: `namespace`, `model`, `image`, `replicas`, `tensor_parallel_size`,
`max_model_len`, `gpu_memory_util`, `student_count`, plus `hf_token` (optional, gated
models only) and the workspace knobs (`workspace_image`, `vllm_host`, `content_repo`).

> **Invariant:** `tensor_parallel_size` must equal the GPU count of the chosen GPU node
> plan. It drives both `--tensor-parallel-size` and the pod's `nvidia.com/gpu` request.

## Multi-model architecture

When the wizard receives two or more models (comma-separated `--model` or `models:`
in config.yaml), the platform switches to multi-model mode. The key differences:

- **Per-model GPU node pools**: Terraform creates a separate LKE node pool per model,
  each with its own label (e.g. `pool=gpu-qwen-qwen3-8b-fp8`).
- **Per-model vLLM StatefulSets**: the Helm chart renders one StatefulSet and ClusterIP
  Service per model (e.g. `vllm-qwen-qwen3-8b-fp8`, `vllm-qwen-qwen3-14b-fp8`), each
  pinned to its GPU pool via `nodeSelector`.
- **Agentgateway routing proxy**: a lightweight Rust gateway reads the `model` field
  from the JSON request body and routes to the correct vLLM backend. Students see a
  single `VLLM_HOST` (`http://agentgateway:8080/v1`).

```
Students (browser)
    │
    ▼  HTTPS (sNN.<base-host>)
Ingress-nginx
    │
    ▼
ws-01..ws-N (code-server pods, CPU pool)
    │
    ▼  http://agentgateway:8080/v1 (single endpoint)
Agentgateway (content-based routing on "model" field)
    │
    ├──► vllm-qwen3-8b:8000       (GPU pool 1, label pool=gpu-qwen-qwen3-8b-fp8)
    └──► vllm-qwen3-14b:8000      (GPU pool 2, label pool=gpu-qwen-qwen3-14b-fp8)
```

Single-model deployments skip the gateway entirely — `VLLM_HOST` points directly to
`vllm:8000` and the cluster layout is identical to the single-model diagram above.

### Multi-model Helm values

```yaml
multi_model: true
models:
  - name: "Qwen/Qwen3-8B-FP8"
    slug: "qwen-qwen3-8b-fp8"
    replicas: 1
    tensor_parallel_size: 2
    gpu_pool_label: "gpu-qwen-qwen3-8b-fp8"
  - name: "Qwen/Qwen3-14B-FP8"
    slug: "qwen-qwen3-14b-fp8"
    replicas: 1
    tensor_parallel_size: 2
    gpu_pool_label: "gpu-qwen-qwen3-14b-fp8"
```

### Multi-model Terraform variables

```hcl
multi_model = true
gpu_pools = [
  { type = "g2-gpu-rtx4000a2-s", count = 1, label = "gpu-qwen-qwen3-8b-fp8" },
  { type = "g2-gpu-rtx4000a2-s", count = 1, label = "gpu-qwen-qwen3-14b-fp8" },
]
```

## Inference is private by design

The vLLM Service is `ClusterIP`. A default-deny NetworkPolicy plus an explicit
`allow-workspaces-to-vllm` rule (or `allow-workspaces-to-gateway` in multi-model) means
only workspace (and capacity-test) pods can reach inference. There is no ingress route to
vLLM. Single-model deployments rely on this network isolation alone (no API key).
Multi-model deployments add API-key auth on the agentgateway (`apiKeyAuthentication`,
mode `Strict`): the key lives in the `gateway-api-keys` Secret and is injected into every
workspace as `VLLM_API_KEY`, which clients send as `Authorization: Bearer`. The gateway is
a router, not a passthrough — it does not serve `GET /v1/models`; list models with
`echo $MODEL_NAMES` in a workspace or `kubectl -n workshop get agentgatewaybackends`.
Off-cluster access is `kubectl port-forward` only — see `quickstart.md`.
