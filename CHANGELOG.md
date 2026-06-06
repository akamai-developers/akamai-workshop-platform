# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/).

## 2026-06-06 — Phase 7: Docs & genericization audit

Finalized the docs to the platform model and removed the last content-specific / personal
references, so the repo reads as a generic, content-agnostic workshop platform.

### Changed
- `infra/docs/runbook.md` — rewritten for **N students** and the `deploy.sh` wizard:
  no-domain-first timeline, subdomain routing (`sNN.<base-host>`), self-signed-cert step,
  capacity-test, generic content + teardown. Removed hardcoded node counts, personal names,
  and the workshop-specific smoke-test scripts.
- `infra/docs/security.md` — corrected to reflect the **default-deny NetworkPolicy + two
  allows** that now ship (the old doc said "no network policies"), the private-inference
  posture (ClusterIP + port-forward, no API key), both TLS modes, and the ingress firewall.
  Genericized the NBA/MCP example.
- `infra/docs/troubleshooting.md` — subdomain routing, generic content-repo guidance
  (dropped NBA/`nba-stats-mcp` and `workshop/solutions`), the self-signed-cert note, the GPU
  capacity-failure path, and the correct default model (`Qwen/Qwen3-8B-FP8`, was the stale
  `Qwen3.5-9B-FP8`).

### Verified
- `grep -rniE "burnersite|stanford|TODO|FIXME|nba-stats|Qwen3\.5"` clean across `infra`,
  README, deploy.sh, Makefile, config (only a historical CHANGELOG note remains).
- All seven `infra/docs/*.md` present; every README quick-start command resolves to a real
  script / make target / file; sizing selftest passes.

## 2026-06-06 — Phase 6: Capacity-test

Made sizing empirical: a parametric concurrency ramp measures real students-per-replica
for a given model + content, instead of relying only on the conservative planning numbers.

### Added
- `infra/scripts/capacity-test.sh` + `infra/manifests/capacity-test-job.yaml` — generalize
  the old load-test into a ramp: runs `vllm bench serve` at increasing `--max-concurrency`,
  records p50/p99 end-to-end latency + output tokens/sec at each level, stops at the highest
  concurrency under the p99 threshold (default 10 s), and reports `active_per_replica` and
  `enrolled_per_replica` (≈2.5× active). Two profiles: **generic** (random short turns, no
  external download) and **workshop** (replays `capacity-prompts.txt` from the content repo).
  `--students N` prints the recommended replica count. `--dry-run` renders the Job (no cluster).
- `make capacity-test` and the wizard `[t]est capacity first` branch both drive it.

### Changed
- NetworkPolicy `allow-workspaces-to-vllm` now allows `app: capacity-test` (was `load-test`)
  to reach `vllm:8000`; the Job carries that label.
- Removed `infra/scripts/load-test.sh` and `infra/manifests/load-test-job.yaml` (superseded).
  `provision.sh` next-steps and `infra/README.md` updated to the capacity-test commands.
- `deploy.sh`: the `capacity-test` verb now hands its own flags straight to
  `capacity-test.sh` (before the deploy flag parser), so `--levels`/`--threshold`/etc. pass through.
- `infra/docs/sizing.md`: capacity-test usage + how to feed the measured number back into sizing.

### Verified (no spend)
- `bash -n` on the wrapper and the embedded Job script; the Job YAML parses and renders with
  overrides applied; helm template shows the updated NetworkPolicy allowlist. (Full
  `kubectl apply --dry-run=client` + a real ramp run happen against the live cluster in Phase 8.)

## 2026-06-06 — Phase 5: The deploy wizard

Tied everything together behind one interactive wizard (`./deploy.sh`) + a `make` front
door. A user answers ~5 questions, sees a sizing + cost preview, confirms once, and gets a
running classroom + `access-cards.csv`. A non-interactive mode drives it headless (CI / e2e).

### Added
- `deploy.sh` — the wizard. Verbs: `deploy` (default), `teardown`, `capacity-test`.
  Collects students/model/content_repo/domain/region (interactive prompts or
  `--config`/flags/env), runs the sizing calculator, prints a cost + sizing preview, runs a
  GPU capacity preflight, writes `terraform.tfvars` + Helm overrides, then drives
  `provision.sh` → `generate-pods.sh` → `access-cards.csv`. `--dry-run` prints the plan and
  writes nothing; `--yes` / `--config` run headless. Token comes from `$TF_VAR_token` /
  `$LINODE_TOKEN` only — never written to a file.
- `infra/scripts/sizing.py` — sizing calculator + ungated model catalog. `plan`
  (students+model → GPU plan, TP, replica/node counts, $/hr; `--json` for the wizard),
  `catalog`, and `selftest` (asserts the PLATFORM-PLAN §3 worked example). Stdlib only;
  prices verified vs the Linode types API.
- `Makefile` — `make deploy` / `dry-run` / `teardown` / `capacity-test` / `sizing-selftest`
  / `help` front door (`ARGS=...` passthrough).
- `config.example.yaml` — copyable template for non-interactive runs.
- `infra/docs/quickstart.md` (deploy → port-forward → teardown, both domain modes) and
  `infra/docs/cost.md` ($/hr breakdown + how to keep the bill down).

### Changed
- `infra/scripts/teardown.sh`: headless mode via `--yes` / `-y` / `AWP_ASSUME_YES` / `FORCE`
  (skips the interactive confirm) so the wizard and e2e smoke test can drive it.
- README quick start is now real (dry-run, `make deploy`, headless `--config`, teardown);
  cost figure corrected to the live-price ~$15.88/hr; doc index adds quickstart + cost.
- `config.yaml` gitignored (`config.example.yaml` is the committed template).

### Notes
- Cost preview uses **live prices** (~$15.88/hr for the 80-student reference), not the
  PLATFORM-PLAN's rounded ~$17.80 (which assumed a pricier CPU node). The GPU structure
  (5× `g2-gpu-rtx4000a4-s` + 5 CPU nodes) matches the plan exactly.

## 2026-06-05 — Phase 4: Domain-optional + region/capacity preflight

Made `domain` the single knob (empty → sslip.io + self-signed TLS; set → Linode DNS +
Let's Encrypt) and added live GPU-region discovery with a capacity preflight, so a class
can be deployed with no domain, no registry, and no GPU stock surprises.

### Added
- `infra/scripts/regions.sh` — live GPU region discovery + capacity preflight using the
  public Linode API (`/v4/regions` capability filter, `/v4/regions/availability` stock
  feed). Subcommands: `list` (the region menu, US-first default), `availability <plan>`,
  `preflight <plan> <region>` (verdict + the three fallbacks: retry region / smaller plan /
  request capacity). Python stdlib only, no `jq` or token required.
- `infra/docs/sizing.md` — GPU plan-name decode, the sizing formula + worked example, the
  ungated model catalog, and the region/capacity note.
- `base_host` Terraform output — `<lb-ip-dashed>.sslip.io` in no-domain mode, else
  `<prefix>.<domain>`. Single source of truth for student URLs in both modes.

### Changed
- `infra/terraform/main.tf`: `data.linode_domain` and both `linode_domain_record.*`
  resources are now gated on `count = var.domain == "" ? 0 : 1`. A `base_host` local
  computes the host for either mode. No DNS resources are created in no-domain mode.
- `infra/scripts/issue-cert.sh`: early-exits the Let's Encrypt path when `DOMAIN` is empty
  and instead generates a self-signed wildcard `*.<base_host>` cert via `openssl`, stored as
  the `workshop-tls` secret (same secret name as domain mode → Ingress unchanged).
- `infra/scripts/provision.sh`: reads `terraform output -raw base_host` (was
  `workshop_base_url`), exports `DOMAIN`/`BASE_HOST`, and always calls `issue-cert.sh`
  (which self-selects self-signed vs lego from `$DOMAIN`).

### Non-goal (intentionally not built)
- vLLM stays private: no ingress route, LoadBalancer/NodePort, or `--api-key`. It remains
  `ClusterIP` + default-deny NetworkPolicy; off-cluster access is `kubectl port-forward` only.

## 2026-06-05 — Phase 3: Generic image + clone-at-startup

Decoupled the workspace image from the workshop content. One generic image (or the stock
code-server image) serves any workshop; content is cloned at pod startup.

### Added
- `infra/images/workspace/startup.sh` — image-agnostic startup: clones `$CONTENT_REPO`
  (default ai-agents-workshop), best-effort `pip install -r requirements.txt`, then starts
  code-server. Works as the dedicated image's ENTRYPOINT *and* as a `command:` override on
  the stock `codercom/code-server` image (degrades gracefully if git/python3 are absent).
- `generate-pods.sh` now emits a `workspace-startup` ConfigMap (built from the canonical
  `startup.sh`) into `manifests/generated/`, applied alongside the workspace pods.

### Changed
- `infra/images/workspace/Dockerfile`: bakes NO content — just code-server + python3 + git +
  `startup.sh` as ENTRYPOINT.
- `workspace-pod-template.yaml`: mounts the `workspace-startup` ConfigMap and overrides the
  container command to run `startup.sh` (the no-Docker path the e2e smoke test uses).
- Renamed `scripts/build-image.sh` → `scripts/build-workspace-image.sh` and simplified it to
  an optional, content-free image build (removed the content-SHA pinning logic).
- Updated `infra/README.md` (stock-vs-prebuilt image paths, current file tree) and
  `provision.sh` next-steps (no build step required).

## 2026-06-05 — Phase 2: Parameterize the infra

Turned the hardcoded manifests into a values-driven Helm chart so the platform can serve
any class size / model / namespace without editing YAML.

### Added
- `infra/helm/` — minimal Helm chart (`Chart.yaml`, `values.yaml`, `templates/`) rendering
  the shared cluster resources: namespace, NetworkPolicies, vLLM Service + StatefulSet, and
  the optional HF token Secret. Values: `namespace`, `model`, `image`, `replicas`,
  `tensor_parallel_size`, `max_model_len`, `gpu_memory_util`, `student_count`, `hf_token`,
  plus workspace knobs. Verified with `helm lint` and `helm template`.
- `infra/docs/architecture.md` — value-vs-generated map and chart overview.

### Changed
- `provision.sh` now renders the chart (`helm template … | kubectl apply`) instead of
  applying static manifests; reads `HELM_VALUES`, `NAMESPACE`, `HELM_BIN`.
- `generate-pods.sh` gained `--namespace/--image/--model/--vllm-host/--content-repo`
  flags (and env defaults); workspace template now uses sentinels for those values.
- `workspace-pod-template.yaml`: namespace, image, `VLLM_HOST`, `MODEL_NAME` are now
  sentinels; added a `CONTENT_REPO` env var (wired fully in Phase 3).
- Namespace is now overridable (`NAMESPACE` env) across `provision/teardown/health-check/
  pre-warm/load-test/generate-pods` instead of a hardcoded `workshop`.
- `terraform.tfvars.example` documents the domain-optional and sizing variables.

### Fixed
- Replaced a stale, non-catalog model id (`lovedheart/Qwen3.5-9B-FP8`) hardcoded in
  `health-check.sh`, `pre-warm.sh`, and `secret.example.yaml` with the parameterized model.

### Removed
- Migrated raw manifests now superseded by the chart: `namespace.yaml`,
  `networkpolicy.yaml`, `vllm-service.yaml`, `vllm-statefulset.yaml`. Removed the
  content-specific `nba-load-test.yaml` (the platform is content-agnostic).

## 2026-06-05 — Phase 1: Foundation & cleanup

Reframed the repo from a single AI-agents *workshop* into **akamai-workshop-platform**,
a content-agnostic platform for spinning up per-student GPU workshop classrooms on LKE.

### Removed
- Duplicate teaching content now sourced from an external content repo at pod startup:
  `workshop/`, `src/`, `docs/` (root), `extend/`, `reference/`, root `Makefile`,
  root `requirements.txt`.

### Added
- `examples/README.md` — points at the default content repo
  (`github.com/akamai-developers/ai-agents-workshop`) and explains bring-your-own content.

### Changed
- Root `README.md` reframed to the platform (what it is, inputs, quick start, cost, teardown).
- Genericized brand-specific values: removed the hardcoded demo domain and institution
  name from `infra/README.md`, `infra/terraform/{variables,main}.tf`, and
  `infra/scripts/{issue-cert,generate-pods,print-access-cards}.sh`.
- `infra/terraform/variables.tf`: `domain` now defaults to `""` (no-domain mode);
  `cert_email` defaults to `""` (domain mode only).

### Fixed
- `infra/manifests/vllm-statefulset.yaml`: comment said "TP=2 across 2-GPU nodes" but the
  arg is `--tensor-parallel-size=4`; corrected to describe TP = node GPU count.
- `infra/README.md`: removed nonsensical "~11s to ~11s" latency claim.

## 2026-05-05

### Phase 1-5: Workshop Content
- Added workshop foundation: config, model selection (vLLM/Ollama/demo), Makefile
- Added core module: MCP tools, display hooks, agent factory, heartbeat reasoning
- Added workshop scripts (00-04): verify, first agent, tool use, memory, heartbeat
- Added workshop guide docs (Kubernetes-the-Hard-Way style)
- Added solutions, reference mapping, and take-home challenges
- Tested against Ollama (qwen3:4b) and demo mode

### Phase 6-8: Infrastructure
- Added Terraform config for Linode Kubernetes Engine (CPU + GPU node pools)
- Added K8s manifests: vLLM deployment, service, namespace, workspace pod template
- Added workspace Dockerfile (code-server + Python + workshop repo)
- Added provisioning, teardown, generate-pods, health-check, pre-warm, and print-access-cards scripts
- Added operational docs: runbook (T-24h to T+60m), troubleshooting, security model
