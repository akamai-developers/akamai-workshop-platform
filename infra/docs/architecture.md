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

## Inference is private by design

The vLLM Service is `ClusterIP`. A default-deny NetworkPolicy plus an explicit
`allow-workspaces-to-vllm` rule means only workspace (and capacity-test) pods can reach
`vllm:8000`. There is no ingress route to vLLM and no API key. Off-cluster access is
`kubectl port-forward` only — see `quickstart.md` (added in a later phase).
