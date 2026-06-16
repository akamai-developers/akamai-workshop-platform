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

## cluster_access: scoped — per-student namespace, RBAC, NetworkPolicy

Default deployments give students **no `kubectl`** — everything runs in one shared
`workshop` namespace and the section above is the whole story. The `cluster_access: scoped`
component (PLAN.md) hands each student in-notebook `kubectl`, which requires **two
independent fences**; one without the other is a false sense of security.

### Fence 1 — control plane (scoped kubeconfig + namespaced RBAC)

`infra/helm/templates/student-namespaces.yaml` renders, per student, a dedicated
`Namespace` (`workshop-sNN`), a `student` `ServiceAccount`, and a **namespaced**
`Role`/`RoleBinding`. The Role grants write on workload objects (pods, services,
configmaps, secrets, pvcs, deployments, statefulsets, replicasets) plus
`pods/portforward` and `pods/exec` — and **nothing cluster-scoped** (no `nodes`,
`namespaces`, or RBAC verbs). So `kubectl get nodes`, `-n kube-system …`, and any other
student's namespace are all **Forbidden**; the student can act only inside their own
namespace.

- `infra/scripts/generate-kubeconfig.sh` mints a **bound** SA token
  (`kubectl create token`, default 30-day TTL) and writes a per-student
  `ws-NN-kubeconfig` Secret whose embedded kubeconfig defaults to the student's
  namespace. The workspace pod mounts it at `~/.kube/config`.
- **The operator admin kubeconfig is never mounted into a workspace** — only the
  short-lived, namespace-scoped SA token is. The pod keeps
  `automountServiceAccountToken: false`; access comes solely from the mounted kubeconfig.

### Fence 2 — data plane (per-namespace NetworkPolicy)

A namespace is an organizational/permissions boundary, **not** a network boundary, so
`infra/helm/templates/student-networkpolicy.yaml` gives each student namespace its own
**default-deny ingress** plus narrow allows: ingress-nginx → workspace:8080,
workspace → own-namespace `vllm:8000`, and (with `agent_deploy`) ingress-nginx →
agent:8080. Cross-namespace pod traffic is denied, so student A cannot reach student B's
pods by IP. **Enforcement depends on the CNI** — LKE ships Cilium, which enforces it; an
unenforced CNI makes this silently decorative (`tests/cilium-enforcement-check.sh` proves
enforcement, `tests/phase3-isolation-check.sh` proves both fences end-to-end).

Egress stays open (`policyTypes: [Ingress]` only), exactly like the shared default-deny
policy: in-notebook `kubectl` tunnels to the API server via egress, and the control plane
is already fenced by RBAC, so an egress rule would break `kubectl` for no isolation gain.

When `cluster_access: none` (the default) none of these objects render and the shared
single-namespace policy above is byte-identical to before.

## object_storage: managed — per-student buckets, bucket-scoped keys

With `object_storage: managed`, `provision-object-storage.sh` creates **one bucket per
student** and mints a **limited access key locked to that single bucket** (read_write).
**That scoping is the isolation:** a student's key physically cannot read or write another
student's bucket — keys are scoped to *buckets*, not prefixes, which is why each student
gets a separate bucket rather than one shared bucket with per-student prefixes.

- Students **never** receive the operator token — only their own bucket-scoped key, injected
  as a per-student Secret (`ws-NN-object-storage`) → env (`AWS_ACCESS_KEY_ID/SECRET`,
  `SESSION_BUCKET/ENDPOINT_URL/REGION`). The workspace pod (and, if enabled, the deployed
  agent) pull it in via `envFrom … optional: true`, so a missing Secret never blocks startup.
- Bucket + key creation take the **region id** (e.g. `us-ord`, the `region` column of
  `object-storage clusters-list`), not the cluster id (`us-ord-1`).
- The key id + secret live only in `infra/manifests/generated/object-storage.csv`
  (gitignored). Re-running preserves existing buckets/keys (the secret is unrecoverable
  after creation), like workspace passwords.
- **Teardown is account-level** (buckets survive `terraform destroy`): `teardown.sh` and the
  e2e-smoke trap revoke every key and empty+delete every bucket **filtered by the run label
  prefix**, idempotently. A leaked bucket/key is a teardown failure.

When `object_storage: none` (the default) no buckets are provisioned and the workspace pod
renders byte-identical (the `__OBJECT_STORAGE_ENVFROM__` sentinel is dropped).

## Access control

- Each workspace gets a unique random password (`openssl rand -hex 16`), stored as a
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
| Object Storage keys (`object_storage: managed`) | Bucket-scoped limited key per student; K8s Secret + `generated/object-storage.csv` (gitignored) | Preserved across re-runs; revoked at teardown |
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
