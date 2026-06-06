# Troubleshooting

`<ns>` is the namespace (`workshop` by default). `<base-host>` is the value printed at the
end of deploy (and in `access-cards.csv`): `<lb-ip-dashed>.sslip.io` in no-domain mode, or
`<prefix>.<domain>` in domain mode.

## Student issues

### "I can't connect to my workspace"

1. Pod running? `kubectl -n <ns> get pod ws-NN`
2. `CrashLoopBackOff` → logs: `kubectl -n <ns> logs ws-NN`
3. `Pending` → node capacity: `kubectl -n <ns> describe pod ws-NN`
4. Running but unreachable → ingress: `kubectl -n <ns> get ingress`
5. **Browser security warning (no-domain mode):** expected — the cert is self-signed. Accept
   the warning once, then log in; WebSockets then work.

### "The agent / inference is slow"

1. vLLM healthy? `kubectl -n <ns> exec vllm-0 -- curl -sf http://localhost:8000/health`
2. GPU utilization: `kubectl -n <ns> exec vllm-0 -- nvidia-smi`
3. Model not loaded (no GPU memory used) → restart: `kubectl -n <ns> rollout restart statefulset/vllm`
4. Sustained slowness under load → you're over capacity. Run `make capacity-test` and add
   replicas (`--gpu-node-count`); see [sizing.md](sizing.md).

### "My code / tools fail"

Workspace content comes from your `content_repo` (cloned at pod startup), so app-level errors
depend on that repo. Check it cloned and its deps installed:

```bash
kubectl -n <ns> logs ws-NN | grep -i "clone\|pip\|startup"
kubectl -n <ns> exec ws-NN -- ls /home/coder   # or the repo's working dir
```

Confirm the workspace can reach inference (proves the NetworkPolicy path):

```bash
kubectl -n <ns> exec ws-NN -- curl -sf http://vllm:8000/v1/models
```

## Infrastructure issues

### vLLM pods won't start

1. GPU nodes present? `kubectl get nodes -l nvidia.com/gpu`
2. Events: `kubectl -n <ns> describe statefulset vllm`
3. Common cause: gpu-operator still installing drivers (3–5 min) or model still downloading.

### No GPU capacity at deploy time

The capacity preflight is advisory; the provision attempt is ground truth. On a capacity
error: retry another GPU region (`infra/scripts/regions.sh list`), drop to a smaller GPU plan,
or request capacity. The deploy fails clean without stranding a billing cluster. See
[sizing.md](sizing.md).

### Workspace pods stuck in Pending

1. CPU capacity: `kubectl describe nodes | grep -A5 "Allocated resources"`
2. Out of capacity → reduce student count or add CPU nodes.

### Ingress not routing

1. Controller running? `kubectl get pods -n ingress-nginx`
2. Rules: `kubectl -n <ns> get ingress -o wide`
3. DNS (domain mode): confirm `*.<prefix>.<domain>` resolves to the LB IP. No-domain mode
   uses sslip.io and needs no DNS.

### Model download slow

The default `Qwen/Qwen3-8B-FP8` is ~18 GB; first download takes a few minutes per replica to
its PVC. Subsequent restarts reuse the cached model. Pick a smaller model (e.g.
`Qwen/Qwen3-4B-Instruct-2507`) for faster cold starts — see
`python3 infra/scripts/sizing.py catalog`.
