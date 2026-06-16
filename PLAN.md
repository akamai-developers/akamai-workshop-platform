# Plan — Component-based workshops

**Branch:** `feat/jupyter-own-inference`
**Status:** design agreed; not yet implemented (this doc is the plan, no code yet)
**Date:** 2026-06-14
**Author:** Du'An Lightfoot

---

## Goal

Extend this platform — *additively, behind flags* — so a single classroom machinery can
run multiple different workshops. Today it runs one shape: browser VS Code + a shared
vLLM endpoint, no `kubectl`. We are adding the pieces needed for two more shapes without
disturbing that default path:

- **Own-your-inference** — each student runs and tunes *their own* vLLM on a dedicated GPU,
  editing manifests and applying them with `kubectl` from a notebook.
- **SA-agent** — each student builds a Strands agent in a notebook, gives it durable memory
  in an Object Storage bucket, and (capstone) deploys it to the cluster.

The principle, proven by the repo's existing `multi_model: true|false` switch: **the default
path stays byte-identical; every new behavior is gated by a flag that defaults to "off."**

## The core idea: components, not presets

We are **not** hardcoding named profiles (`agent` / `own-inference` / `sa-agent`). Those names
don't survive contact with the next workshop. Instead the platform exposes a **catalog of
independent per-student components**, and **a workshop is just a config file that selects
component values.** Adding a future workshop = writing a new config, *not* changing platform
code.

Selection happens **once per classroom, by the operator at deploy time** — every student in a
room gets the same composition. Mixed-mode rooms are explicitly out of scope.

### Component catalog (v1)

| Component | Values | Controls | Default |
|---|---|---|---|
| `editor` | `code-server` \| `jupyter` | The workspace UI | `code-server` |
| `content_repo` | git URL | Which lessons get cloned into each workspace | `""` (default workshop) |
| `inference` | `shared-vllm` \| `dedicated-vllm` \| `external` | Where the model comes from | `shared-vllm` |
| `gpus_per_student` | `1`  (value `2` reserved / v2) | Only when `inference: dedicated-vllm` | `1` |
| `cluster_access` | `none` \| `scoped` | Per-student namespace + scoped kubeconfig + NetworkPolicy | `none` |
| `agent_deploy` | `none` \| `plain`  (`kagent` reserved / v2) | A "ship the agent to k8s" capability (needs `cluster_access: scoped`) | `none` |
| `object_storage` | `none` \| `managed`  (`own-account` reserved / v2) | Durable agent memory bucket | `none` |
| *(always on)* | — | password, per-student ingress, TLS, access cards, content clone | — |

### The two workshops as configs

```
# Own-your-inference
editor:            jupyter
inference:         dedicated-vllm
gpus_per_student:  1            # or 2 for the two-models-+-routing lab
cluster_access:    scoped
agent_deploy:      none
object_storage:    none
content_repo:      <agents-that-own-their-inference>

# SA-agent
editor:            jupyter
inference:         shared-vllm  # or external (OpenAI/Anthropic)
cluster_access:    scoped       # module 7 deploys into the student's namespace
agent_deploy:      plain        # or kagent for the cloud-native-agents capstone
object_storage:    managed      # platform-provisioned per-student bucket
content_repo:      <akamai-sa-agent>
# student also pastes their own read-only Linode token for the account-read modules
```

The big reuse win: **`cluster_access: scoped`** powers *both* own-inference's "tune your own
vLLM" *and* SA-agent's "deploy your agent." Build it once.

---

## Design decisions (and why)

### Ground-truth corrections to the original design doc

While reading the repo, three claims in `aie-workshop-design.md` proved stale/wrong against
the current code — they reduce the work:

1. **Ingress already sets `proxy-send-timeout: "3600"`** (`generate-pods.sh`) alongside
   `proxy-read-timeout`. Jupyter kernel websockets are already covered; no ingress change needed.
2. **The NetworkPolicy is ingress-only** (`policyTypes: [Ingress]`). Egress is unrestricted, and
   `security.md` itself notes `kubectl` "tunnels via the API server, so the default-deny policy
   doesn't block it." So the doc's prescribed *egress-to-API-server* NetworkPolicy work is
   **unnecessary** — the only blockers to in-notebook `kubectl` are the missing ServiceAccount /
   RBAC / kubeconfig.
3. **Doc drift:** `security.md` says passwords use `openssl rand -hex 4`; the script uses
   `-hex 16`. Fix the doc to `-hex 16`.

### `cluster_access: scoped` = two independent fences

A namespace is an *organizational + permissions* boundary, **not** a network boundary. The
moment a student gets `kubectl`, isolation requires **both**:

| Fence | Mechanism | Stops |
|---|---|---|
| Control plane | scoped kubeconfig (ServiceAccount + namespaced Role/RoleBinding) | Student A *administering* B's resources via the API |
| Data plane | per-namespace NetworkPolicy (default-deny + narrow allows) | Student A's pods *sending packets* to B's pods |

The kubeconfig alone is a false sense of security — it locks the API while the flat pod network
stays wide open. Both are required. **Enforcement depends on the CNI: LKE ships Cilium, which
does enforce NetworkPolicy** (verify on the exact LKE version in rehearsal — an unenforced
policy is silently decorative).

`scoped` therefore implies **one namespace per student** (today everything shares one `workshop`
namespace, which is fine *only* because no one has `kubectl`).

### `inference` and the GPU scenarios

- `shared-vllm` (today): ~16 students per vLLM replica. Cheapest. For "use an agent" workshops.
- `dedicated-vllm`: one vLLM per student on their own GPU node, **deliberately under-tuned** so
  the saturate/optimize lab has something to fix. `gpus_per_student: 1` (small model, the
  affordable default) or `2` (the two-models + agentgateway-routing lab).
- `external`: no platform inference; the agent calls OpenAI/Anthropic/etc.

**GPU stock is the #1 real-world constraint**, and dedicating GPUs is what makes it bite:
~52 GPUs (shared, 200 students) → 200 (1 each) → 400 (2 each), all in **one region** (one LKE
cluster is single-region). Mitigations: reserve capacity ahead, size headcount to *confirmed*
stock (don't pair students), rehearse a backup region + a degrade path, stagger provisioning
(20-creates/15s limit), and **preflight live region availability before committing** rather than
discovering shortfall when pods won't schedule.

### `object_storage: managed` — per-student buckets with real isolation

Promoted to a v1 component. It decouples "needs a bucket" from "needs account access": a
workshop that only needs agent memory hands students a working bucket and they bring nothing.

- At deploy, a provisioning step (sibling to `generate-pods.sh`) uses the **operator token** to
  create **one bucket per student** and mint a **bucket-scoped limited access key** for each
  (Linode Object Storage keys can be locked to a single bucket, read-write).
- **This scoping is the isolation:** a student's key physically cannot read another student's
  bucket. Students never receive the operator master key.
- The key + bucket + endpoint + region are injected as a per-student **Secret → env**
  (`AWS_ACCESS_KEY_ID/SECRET`, `SESSION_BUCKET`, `SESSION_ENDPOINT_URL`, `SESSION_REGION`) — the
  vars the SA agent already reads.
- **Separate bucket per student, not one shared bucket with prefixes** — Linode limited keys
  scope to *buckets*, not prefixes, so a shared bucket couldn't enforce isolation. Cost: 200
  buckets may exceed a default bucket-count limit → raise via ticket ahead of time (storage spend
  itself is trivial). Real isolation beats dodging a liftable limit.
- Teardown empties + deletes buckets and revokes keys; re-runs are idempotent (preserve, like
  passwords).
- `own-account` (student creates a bucket in their own account) stays available; `none` is default.
- Verified against the live account: Object Storage is enabled with read/write. Key and bucket
  creation require the REGION id (e.g. `us-iad`, the `region` column from `clusters-list`), NOT the
  cluster id (`us-iad-1`); an empty `--regions` returns a 500, a wrong value a 400. The provisioning
  script must resolve and pass the correct region id.

### `agent_deploy` — `plain` vs `kagent`

A "ship the agent to k8s" capability for SA-agent module 7. Requires `cluster_access: scoped`.
Deploy target is the **classroom cluster's scoped namespace**, not a freshly-provisioned personal
LKE (a real cluster spin-up is 15–20 min — too slow for a live module).

- **`plain`** — deploy the agent as an ordinary **Deployment + Service**, fronted by the
  **per-student ingress the platform already generates** (no NodeBalancer). **No new cluster
  software.** "Deploy" = `kubectl apply`; "modify" = reuse the platform's **clone-at-startup**
  pattern so the agent pod re-clones the student's repo on `rollout restart` — **no Docker build
  inside the locked-down non-root pod.** Low-risk default/fallback.
- **`kagent`** — declare the agent as a **kagent Agent CRD** and `kubectl apply` it; the kagent
  controller runs it. On-theme "agents as first-class Kubernetes objects" capstone. kagent is
  "bring your own framework," so it can orchestrate the Strands app — but:
  - it installs **cluster-wide** (Helm chart + CRDs + controller); the **build** installs it once,
    students author CRDs in their namespace (same build-vs-content split).
  - the Strands+FastAPI app must be **wrapped to kagent's interface** (A2A/MCP) — build + rehearse
    this against a **pinned** kagent version (young CNCF-sandbox project, expect churn).
  - scoped RBAC must allow students to create kagent's **namespaced** CRDs.

Ship `plain` as the dependable default; offer `kagent` as the opt-in capstone.

### Build-vs-content split (the rule)

- **Build / deployment (operator, cluster-wide):** cluster + CNI + GPU operator, namespaces, RBAC,
  NetworkPolicies, managed buckets + keys, kagent install (if enabled), the under-tuned per-student
  vLLM, the deployed-agent scaffolding.
- **Workshop content (student, in their own namespace):** their vLLM tuning, a 2nd model + gateway
  routing, their agent code + the Agent CRD / Deployment, their guardrail config. (The notebook
  `/metrics` helper already lives in the content repo as `common/metrics.py`.)

---

## Change map (plan — files, not code)

Phased so the default `code-server` + `shared-vllm` path stays byte-identical and each phase is
verifiable on its own.

**Phase 0 — Component scaffolding + doc fix (no behavior change)**
- `infra/helm/values.yaml` — add component keys with today's behavior as defaults.
- `config.example.yaml` — document the component catalog.
- `infra/docs/security.md` — fix `hex 4` → `hex 16`.
- Verify: `helm template` output for defaults is unchanged; existing tests pass.

**Phase 1 — `editor: jupyter`**
- `infra/images/workspace/startup.sh` — branch at the final `exec`: launch `jupyter lab` (map
  `$PASSWORD` → token) when `WORKSPACE_TYPE=jupyter`, else code-server. Keep port 8080.
- `infra/images/workspace/Dockerfile` — a Jupyter image variant + deps; `build-workspace-image.sh`
  builds it.
- `infra/manifests/workspace-pod-template.yaml` — add `WORKSPACE_TYPE` env (placeholder).
- `infra/scripts/generate-pods.sh` + `deploy.sh` — thread `workspace_type`.
- Verify: e2e smoke on code-server path unchanged; a Jupyter pod serves notebooks + a web terminal
  through ingress; kernel websocket stays connected >1h.

**Phase 2 — `cluster_access: scoped`** (the shared workhorse)
- New helm templates: per-student `Namespace`, `ServiceAccount`, namespaced `Role`/`RoleBinding`
  (write on deployments/statefulsets/pods/services/configmaps + `pods/portforward`, plus kagent
  CRDs when enabled), per-namespace NetworkPolicy (default-deny + ingress-nginx→workspace +
  workspace→own-vLLM).
- New `infra/scripts/generate-kubeconfig.sh` — mint a kubeconfig from the SA token, ship as a
  per-student Secret mounted at `~/.kube/config`; default context = the student's namespace.
- `generate-pods.sh` — per-student-namespace mode (vs today's single shared namespace).
- Verify: a student kubeconfig can edit only its namespace; a NetworkPolicy test proves student A
  cannot reach student B's vLLM by IP.

**Phase 3 — `object_storage: managed`**
- New `infra/scripts/provision-object-storage.sh` — create per-student bucket + bucket-scoped key;
  emit per-student Secret; idempotent; teardown deletes/revokes (wire into `teardown.sh`).
- `workspace-pod-template.yaml` + `generate-pods.sh` — optional object-storage Secret → env.
- Verify: agent writes/reads sessions; one student's key is denied on another's bucket.

**Phase 4 — `inference: dedicated-vllm` (1–2 GPUs)** *(largest; untestable without a cluster)*
- New per-student vLLM `Deployment` template in the student namespace, pinned to their GPU node,
  shipped **deliberately under-tuned** (low `--gpu-memory-utilization`, short `--max-model-len`).
- `infra/scripts/sizing.py` — per-student GPU sizing for dedicated mode.
- `infra/scripts/regions.sh` — capacity preflight (fail early if a region can't satisfy N×GPUs).
- 2-GPU path: a 2nd vLLM + agentgateway routing, deployed by the student (content).

**Phase 5 — `agent_deploy: plain`**
- New agent `Deployment` + `Service` template in the student namespace; reuse the per-student
  ingress; reuse clone-at-startup so "modify" needs no Docker build.

**Phase 6 — `agent_deploy: kagent`** *(DEFERRED to v2 — not built in this run; reserve the enum value only)*
- Build-side kagent Helm install (component-gated); RBAC for namespaced Agent CRDs; wrap the
  Strands app to kagent's interface; pin the kagent version.

Docs to touch throughout: `infra/docs/architecture.md`, `security.md` (per-student namespace +
RBAC + NetworkPolicy section), `cost.md`/`sizing.md` (dedicated-GPU + bucket counts), `runbook.md`
(reset path for a bricked student manifest, facilitator runbook).

---

## Out of scope for v1 (candidates for v2)

- Workshop-supplied account token (students bring their own for now).
- KServe / autoscaling (cut — no spare GPUs to scale into per student).
- **kagent** (`agent_deploy: kagent`) — deferred; reserve the enum value, build no kagent code in v1 (young dependency, content not ready, unverifiable in the single smoke).
- **2-GPU dedicated** (`gpus_per_student: 2`) + per-student agentgateway routing — deferred to v2.
- **`object_storage: own-account`** — deferred to v2 (near no-op; reserve the value).
- `gpus_per_student: 4`, projected Grafana wall, mixed-mode classrooms.
- Personal-LKE deploy target for the agent (too slow for a live module).

## Top risks / must-dos before an event

1. **GPU stock** — reserve ahead; size headcount to confirmed stock; preflight; backup region.
2. **Raise the Object Storage bucket-count limit** via ticket well ahead (managed mode at 200).
3. **Reset path for a bricked student vLLM/manifest** + a facilitator runbook + a ~1:25 TA ratio.
4. **Rehearse** metric names against the pinned vLLM version, NetworkPolicy enforcement on the
   exact LKE/Cilium version, kernel websocket longevity, and (if used) kagent wrapping.
