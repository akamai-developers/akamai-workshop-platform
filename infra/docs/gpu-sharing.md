# GPU sharing: two models on one card

The `gpu_sharing: timeslicing` component lets a single physical GPU host more than one
pod, so a student can run two vLLM servers on one card. It powers the "two models, one
GPU" lab (module 07 of the inference workshop).

Default is `gpu_sharing: none` (one pod per GPU, the exclusive-access behavior). Turning
it on adds NVIDIA time-slicing to the GPU nodes and nothing else; the default classroom
renders and behaves identically.

## Deploy a time-sliced classroom

```bash
export TF_VAR_token="$LINODE_TOKEN"
./deploy.sh deploy --yes \
  --students 1 --model Qwen/Qwen3-4B-Instruct-2507 \
  --editor jupyter --inference dedicated-vllm --cluster-access scoped \
  --gpus-per-student 1 --gpu-sharing timeslicing \
  --gpu-node-type g2-gpu-rtx4000a1-s --gpu-node-count 1 --tp 1 \
  --domain "" --region us-ord
```

`--gpu-sharing timeslicing` requires `--inference dedicated-vllm`. Set the slice count
with `--gpu-timeslicing-replicas N` (default 2, which is one slice per model in the lab).

## What the platform configures

Three pieces make the lab work. All are gated on `gpu_sharing=timeslicing`, so the
default classroom is unchanged.

| Piece | Where | Why |
|---|---|---|
| NVIDIA time-slicing | `provision.sh` patches the gpu-operator ClusterPolicy after install | the card advertises N logical GPUs, so two pods can schedule on it |
| NetworkPolicy | `infra/helm/templates/student-networkpolicy.yaml` | the workspace can reach any inference pod in its own namespace on 8000, not only one named `vllm` |
| RBAC scale | `infra/helm/templates/student-namespaces.yaml` | the student Role gains `deployments/scale`, so `kubectl scale` works (not just `kubectl edit`) |

Confirm time-slicing took effect (a single RTX4000 reports 2):

```bash
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" gpu="}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}'
```

## The lab: two models on one GPU

The baseline classroom runs one vLLM per student (Deployment `vllm`). It holds one of the
two slices and most of the card's 20 GB. To run two models, free that slice first.

```bash
# 1. free the baseline vLLM (its slice and its memory)
kubectl scale deploy/vllm --replicas=0

# 2. deploy two small models on the shared card (two-models.yaml ships with module 07)
kubectl apply -f two-models.yaml
kubectl rollout status deploy/vllm-fast
kubectl rollout status deploy/vllm-smart

# 3. both serve, on one physical GPU
kubectl exec deploy/vllm-fast  -- curl -s http://localhost:8000/v1/chat/completions  -H 'Content-Type: application/json' -d '{"model":"Qwen/Qwen2.5-1.5B-Instruct","messages":[{"role":"user","content":"hi"}],"max_tokens":8}'
kubectl exec deploy/vllm-smart -- curl -s http://localhost:8000/v1/chat/completions  -H 'Content-Type: application/json' -d '{"model":"Qwen/Qwen2.5-3B-Instruct","messages":[{"role":"user","content":"hi"}],"max_tokens":8}'
```

Why step 1 is required, not optional: time-slicing shares compute, not memory. Each model
claims its `--gpu-memory-utilization` fraction of the whole card, and the fractions sum.
Two servers at 0.45 each fit a 20 GB card; the baseline (0.7) plus both does not. The
baseline also holds one of the two slices, so without scaling it down a third pod stays
Pending.

From inside the workspace, the student's notebook reaches the two servers at
`http://vllm-fast:8000` and `http://vllm-smart:8000` and routes between them in Python.

## Verify a student workspace

From a Jupyter terminal or a notebook cell (prefix shell commands with `!`):

```bash
!python verify_env.py     # vLLM PASS, kubectl PASS; object storage SKIP if not enabled
!kubectl get pods         # your namespace: allowed
!kubectl get deploy       # your vllm deployment: allowed
!kubectl scale deploy/vllm --replicas=0   # allowed (the module-07 step)
!kubectl get nodes        # Forbidden, by design (see below)
```

`kubectl get nodes` returning **Forbidden** is correct, not a failure. Each student runs
as `serviceaccount:<namespace>:student`, scoped to their own namespace. Cluster-scoped
resources (nodes) and other namespaces (kube-system, other students) are denied. That
error message is the isolation fence working.

## Current deployment

| | |
|---|---|
| URL | `https://s01.172-236-113-245.sslip.io/` (self-signed TLS; accept the warning once) |
| Namespace | `workshop-s01` |
| GPU | 1x `g2-gpu-rtx4000a1-s`, time-sliced to 2 logical GPUs |
| Baseline model | `Qwen/Qwen3-4B-Instruct-2507` at `http://vllm:8000/v1` |
| Two-models lab | `Qwen/Qwen2.5-1.5B-Instruct` (vllm-fast) + `Qwen/Qwen2.5-3B-Instruct` (vllm-smart) |
| Workspace password | `infra/manifests/generated/access-cards.csv` |
| Cost | about $0.74/hr while up |

Tear down (stops billing):

```bash
TF_VAR_token=$LINODE_TOKEN ./deploy.sh teardown --yes --namespace workshop
```
