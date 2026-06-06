# Security model

The platform spins up an **ephemeral classroom** that is destroyed after the event. The
threat model prioritizes, in order:

1. **Student isolation** — one student cannot affect another's workspace.
2. **Cluster integrity** — workspace pods cannot escalate privileges or reach cluster resources.
3. **Inference containment** — the GPU endpoint is never exposed to the public internet.

Non-goals (given the ephemeral nature): long-term credential rotation, audit logging,
multi-tenant hardening beyond the controls below.

## Pod security

Every workspace pod runs with a locked-down security context:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
```

- **Non-root** — runs as UID 1000 (the `coder` user).
- **No privilege escalation** — blocks setuid binaries.
- **All capabilities dropped** — no Linux capabilities beyond baseline.

The namespace is labeled for the Pod Security Standards **baseline** profile.

## Network policy (default-deny)

The namespace ships a **default-deny ingress** NetworkPolicy plus two explicit allows
(`infra/helm/templates/networkpolicy.yaml`):

- `allow-ingress-to-workspaces` — only the ingress-nginx namespace may reach workspace
  pods on 8080.
- `allow-workspaces-to-vllm` — only `app: workspace` (and the `app: capacity-test` job) may
  reach `vllm:8000`. Students cannot reach each other; everything else is denied.

### Inference is private by design

The `vllm` Service is `ClusterIP` — there is **no ingress route, LoadBalancer/NodePort, or
API key** for it. Students call `http://vllm:8000/v1` from inside their code-server. The
only public routes are the per-student code-servers. Off-cluster access is **`kubectl
port-forward`** only (it tunnels via the API server, so the default-deny policy doesn't block
it) — see [quickstart.md](quickstart.md). This keeps the GPU endpoint off the public internet
and removes the abuse/cost surface. A public inference endpoint is an explicit non-goal.

## Access control

- Each workspace gets a unique random password (`openssl rand -hex 4`), stored as a
  Kubernetes Secret and injected via env.
- Students receive passwords on printed access cards — no shared credentials.
- No SSH to nodes or pods — code-server over HTTPS only.

## TLS

- **No-domain mode (default):** a self-signed wildcard `*.<base-host>` cert (one
  `workshop-tls` secret). Students accept the browser warning once.
- **Domain mode:** a Let's Encrypt wildcard via lego + Linode DNS-01 (trusted, no warning).
- Same secret name (`workshop-tls`) in both modes; terminated at ingress-nginx.

## Ingress firewall

Terraform defines a Cloud Firewall allowing only 80/443 from `allowed_cidr` (default open;
set it to a classroom CIDR to restrict). Per-node worker firewalls are installed via the
Linode cloud-firewall controller.

## Credentials

| Credential | Storage | Rotation |
|---|---|---|
| Linode API token | Env var (`TF_VAR_token` / `LINODE_TOKEN`) — never written to a file by the wizard | Per-event |
| Workspace passwords | K8s Secrets | Generated per deployment (`--rotate` to reset) |
| HuggingFace token | Not required (ungated models only); optional Secret for gated models | N/A |
| vLLM auth | None — endpoint is private (ClusterIP + default-deny) | N/A |

## Cluster lifecycle

- Provisioned shortly before the event; destroyed with `make teardown` after.
- No persistent volumes beyond the vLLM model cache PVCs (deleted on teardown).
- Terraform state is local (not a remote backend).

## Hardening for longer-lived use

The defaults suit an ephemeral classroom. For a longer-lived deployment, consider: PSS
**restricted** profile, audit logging on LKE, a remote encrypted Terraform backend, resource
quotas on the namespace, and cert-manager for TLS lifecycle.
