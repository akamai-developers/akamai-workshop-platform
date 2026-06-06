# BUILD_PROGRESS — akamai-workshop-platform

Handoff file for the multi-session autonomous build. Read this + `PLATFORM-PLAN.md` +
`PROMPT.md` first every session. **Not committed** (gitignored).

Branch: `rebuild/akamai-workshop-platform`

---

## Status: Phases 1–7 COMPLETE ✓ · Phase 8 BLOCKED (invalid token) · code-only work done

### ⛔ Phase 8: REAL LKE e2e — STILL BLOCKED (re-checked 2026-06-06, 7th session) — needs a VALID token
- **7th re-check (this session, 2026-06-06):** same 64-char `$TF_VAR_token`, STILL 401
  `Invalid Token` on `GET /v4/profile`. Verified clean: NO `*.tfstate`/`.lock.info` under
  `infra/terraform` (terraform provisioned nothing), no `infra/manifests/generated/`, no
  `access-cards.csv`, `linode-cli` NOT authenticated (prompts for first-time setup → no
  cluster can exist under it). Branch correct, working tree clean. Nothing provisioned,
  nothing billing. Did NOT fake the deploy. STOPPED. No code changes — Phases 1–7 stand.
  The blocker is purely the credential; all code/tooling is ready.
- **6th re-check (2026-06-06):** same 64-char `$TF_VAR_token`, STILL 401
  `Invalid Token` on `GET /v4/profile`. Verified clean: no `*.tfstate`/`.lock.info` (outside
  `.terraform/`), no `infra/manifests/generated/`, no `access-cards.csv`, `linode-cli` NOT
  authenticated (so no cluster can exist under it). Branch correct, working tree clean.
  Nothing provisioned, nothing billing. Did NOT fake the deploy. STOPPED. No code changes —
  Phases 1–7 stand. The blocker is purely the credential; all code/tooling is ready.
- **5th re-check (2026-06-06):** same 64-char `$TF_VAR_token`, STILL 401
  `Invalid Token` on `GET /v4/profile`. Verified clean: no `*.tfstate`, no `.lock.info`,
  no `infra/manifests/generated/`, no `access-cards.csv`, `linode-cli` NOT authenticated
  (so no cluster can exist under it). Branch correct, working tree clean. Nothing
  provisioned, nothing billing. Did NOT fake the deploy. STOPPED. No code changes —
  Phases 1–7 stand. The blocker is purely the credential; all code/tooling is ready.
- **4th re-check (2026-06-06):** same 64-char `$TF_VAR_token`, STILL 401
  `Invalid Token` on `GET /v4/profile`. Verified clean: no `*.tfstate`, no `.lock.info`,
  no `infra/manifests/generated/`, no `access-cards.csv`, `linode-cli` NOT authenticated
  (so no cluster can exist under it). Nothing provisioned, nothing billing. Did NOT fake
  the deploy. STOPPED. No code changes — Phases 1–7 stand. The blocker is purely the
  credential; all code/tooling is ready and unchanged.
- **3rd re-check (2026-06-06):** same 64-char `$TF_VAR_token`, STILL 401
  `Invalid Token` on `GET /v4/profile`. Verified clean: no `*.tfstate`, no lock file,
  `linode-cli` not authenticated (so no cluster can exist under it). Nothing provisioned,
  nothing billing. Did NOT fake the deploy. STOPPED. No code changes — Phases 1–7 stand.
- **Prior re-check:** `$TF_VAR_token` present (64 chars) but STILL invalid —
  `GET /v4/profile` → `HTTP 401 {"errors":[{"reason":"Invalid Token"}]}`. Verified no
  `*.tfstate`, no `.terraform.tfstate.lock.info`, no `awp-e2e-smoke` cluster (linode-cli
  not even authenticated). Nothing provisioned, nothing billing. Did NOT fake the deploy. STOPPED.

- The `e2e-smoke.sh` script is BUILT, syntax-checked, and correctly blocks on a bad token
  (commit b5d175e). **It has NOT been run** — no cloud resources were created (no
  `terraform.tfstate` has ever existed → terraform provisioned nothing; nothing is billing).
- **Why blocked:** `$TF_VAR_token` is set (64 chars) but the Linode API STILL rejects it:
  `GET /v4/profile` → `HTTP 401 {"errors":[{"reason":"Invalid Token"}]}` (re-verified this
  session, 2026-06-06). Per the safety rules, do NOT fake the deploy.
- **This session's actions:** re-validated the token (still 401); removed a stale
  `infra/terraform/.terraform.tfstate.lock.info` left by an aborted apply (no state existed,
  so it was safe — it would otherwise block the next `terraform apply`). No spend. STOPPED.
- **Exact next step to finish Phase 8 (one session, will spend ~$1):**
  ```bash
  export TF_VAR_token="<a VALID Linode token: Kubernetes/Linodes/NodeBalancers/Volumes R-W>"
  curl -sf -H "Authorization: Bearer $TF_VAR_token" https://api.linode.com/v4/profile  # must be 200
  ./infra/scripts/e2e-smoke.sh            # optional: --region us-sea if us-ord GPU is out of stock
  ```
  The script deploys the cheapest footprint, asserts the chain, ALWAYS tears down (EXIT
  trap), and verifies via `linode-cli lke clusters-list` that nothing remains. It writes
  measured numbers to `infra/docs/e2e-results.md`. After a green run: add the README
  "Verified end-to-end" note + final CHANGELOG entry (Phase 8 docs), and record results here.
- Tooling for Phase 8 is READY: terraform 1.9.8, kubectl 1.31, helm 3.16, openssl,
  linode-cli, curl all on PATH. No e2e cluster currently exists (verified: none).

### Phase 7: Docs & genericization audit — DONE (2026-06-06) — commit b8def52
- [x] Rewrote runbook.md (N students, deploy.sh wizard, subdomain routing, self-signed cert,
      capacity-test, teardown), security.md (default-deny NetworkPolicy + allows that ship,
      private-inference posture, both TLS modes), troubleshooting.md (generic content-repo,
      correct default model). Removed personal names + NBA/MCP/workshop-script references.
- [x] Off-cluster `kubectl port-forward` access documented in quickstart.md (Phase 5).
- [x] Verified: burnersite/stanford/TODO/FIXME/nba-stats/Qwen3.5 grep clean; all 7 docs
      present; every README quick-start command resolves; sizing selftest passes.

### Phase 6: Capacity-test — DONE (2026-06-06) — commit fbfeb39
- [x] `capacity-test.sh` + `capacity-test-job.yaml`: concurrency ramp → p50/p99 + tok/s →
      active/enrolled per replica. generic + workshop profiles. `--dry-run` renders, `--students`
      recommends replica count. NetworkPolicy now allows `app: capacity-test`. Removed old
      load-test.sh + load-test-job.yaml. deploy.sh capacity-test verb passes flags through.
- [x] Verified: bash -n wrapper + embedded Job script; Job YAML parses + renders; helm template
      shows updated allowlist. (kubectl --dry-run=client + real ramp run are in Phase 8.)



### Phase 5: The deploy wizard — DONE (2026-06-06) — commit 93e5e03
- [x] `deploy.sh` wizard: verbs deploy/teardown/capacity-test. Interactive prompts +
      non-interactive `--yes --config config.yaml` / flags / env. Writes terraform.tfvars +
      `infra/manifests/generated/helm-values.yaml`, drives provision → generate-pods → CSV.
      Token only from $TF_VAR_token/$LINODE_TOKEN (never a file). `--dry-run` writes nothing.
- [x] `infra/scripts/sizing.py`: ungated catalog + formula. `plan`/`catalog`/`selftest`.
      Policy: 1 replica + 1 CPU node per ~16 students; small class (≤24) → cheapest plan that
      fits; else repo-default a4-s TP=4 pool. Prices verified vs Linode types API.
- [x] `Makefile` (deploy/dry-run/teardown/capacity-test/sizing-selftest/help, ARGS passthrough).
- [x] `config.example.yaml`; `config.yaml` gitignored. teardown.sh headless `--yes`.
- [x] Docs: quickstart.md, cost.md; README quick start real; sizing.md cost reconciled.
- [x] Verified: selftest PASS; dry-run 80/Qwen3-8B-FP8 → 5× g2-gpu-rtx4000a4-s + 5 CPU,
      writes nothing; helm-values render + tfvars `terraform validate` OK; gate clean.

**Cost note:** wizard prints LIVE prices (~$15.88/hr for 80-student ref), NOT the plan's
rounded ~$17.80 (which assumed a pricier CPU node, $0.60 vs real $0.216). GPU structure
(5× a4-s + 5 CPU) matches the plan exactly. selftest asserts $14–20 band, not exact figure.



Tooling: `helm` v3.16.3, `terraform` v1.9.8 in `~/bin` (not committed). `kubectl` v1.31.0
now present at /usr/local/bin (Phase 8 still verify before relying on it). `linode-cli`,
`jq`, `python3`, `openssl`, `envsubst` present.

### Phase 4: Domain-optional + region/capacity preflight — DONE (2026-06-05) — commit f618dfa
- [x] `domain` is the single knob. terraform: `data.linode_domain` + both
      `linode_domain_record.*` gated on `count = var.domain == "" ? 0 : 1`; `base_host` local
      + output (`<lb-ip-dashed>.sslip.io` no-domain, else `<prefix>.<domain>`).
- [x] issue-cert.sh: early-exit lego path when DOMAIN empty → openssl self-signed wildcard
      `*.<base_host>` stored as `workshop-tls` (same secret name both modes). Verified:
      cert generates with correct SAN, loads as a valid `kubectl create secret tls` YAML.
- [x] provision.sh: reads `terraform output -raw base_host` (was `workshop_base_url`),
      exports DOMAIN/BASE_HOST, always calls issue-cert.sh (self-selects mode from $DOMAIN).
- [x] regions.sh: `list` / `availability <plan>` / `preflight <plan> <region>` via public
      Linode API (python stdlib). Verified live: `list` returns 21 GPU regions, us-ord default.
- [x] vLLM stays private — NO ingress/LB/api-key added (non-goal respected).
- [x] Verified: `terraform validate` OK (value-independent → covers both domain modes);
      `bash -n` all touched scripts; helm template regression OK.
- [x] Docs: `infra/docs/sizing.md` (GPU decode + formula + worked example + model catalog +
      region/capacity note); README + infra/README doc lists + DNS table; CHANGELOG Phase 4.

Decisions this phase:
- **Self-signed via openssl, 365-day, SAN = `*.<base_host>` + bare `<base_host>`.** Stored
  under the SAME `workshop-tls` secret name as domain mode so Ingress + generate-pods are
  unchanged between modes.
- **regions.sh availability feed is advisory only** — every g1/g2-gpu reads available=false
  even when stock exists. Ground truth = the provision attempt; preflight prints the 3
  fallbacks (retry region / smaller plan / request capacity) instead of hard-blocking.
- Capacity "provision GPU pool first" ordering is enforced at the wizard/e2e layer (Phase 5/8);
  the terraform GPU node pool already exists as a separate resource for clean failure.

### Phase 2: Parameterize the infra — DONE (2026-06-05)
- [x] Created `infra/helm/` Helm chart (Chart.yaml, values.yaml, templates/{namespace,
      networkpolicy,vllm-service,vllm-statefulset,secret}.yaml). `helm lint` + `helm template`
      verified; `--set model=… --set tensor_parallel_size=…` propagate to args AND nvidia.com/gpu.
- [x] provision.sh renders chart via `helm template | kubectl apply` (HELM_VALUES/NAMESPACE/HELM_BIN).
- [x] generate-pods.sh: new flags --namespace/--image/--model/--vllm-host/--content-repo;
      workspace-pod-template.yaml uses sentinels __NAMESPACE__/__WORKSPACE_IMAGE__/__VLLM_HOST__/
      __MODEL__/__CONTENT_REPO__. End-to-end render tested → valid YAML, all sentinels substituted.
- [x] Namespace overridable (NAMESPACE env) across provision/teardown/health-check/pre-warm/
      load-test/generate-pods.
- [x] Fixed stale model id (lovedheart/Qwen3.5-9B-FP8) → parameterized MODEL in health-check/pre-warm/secret.example.
- [x] terraform.tfvars.example updated; `terraform validate` passes (domain="" and domain set).
- [x] Removed migrated raw manifests + nba-load-test.yaml.
- [x] Docs: architecture.md added; README doc list + CHANGELOG Phase 2 entry.

Decisions this phase:
- **Helm chart, not envsubst.** Matches the blueprint tree + the verify command. helm vendored
  to ~/bin. Runtime needs helm+kubectl (Phase 8 e2e script must vendor both like terraform).
- **Workspace pods stay in generate-pods.sh, NOT the chart** — idempotent password preservation
  can't be a stateless template render. Chart covers only shared cluster resources.
- Chart secret always created (empty hf_token default) → removed provision's conditional secret.yaml logic.
- `tensor_parallel_size` drives both --tensor-parallel-size and the nvidia.com/gpu request (1 value).


### Phase 1: Foundation & cleanup — DONE (2026-06-05)
- [x] Created + switched to branch `rebuild/akamai-workshop-platform`
- [x] Cut duplicate teaching content: `workshop/ src/ docs/ extend/ reference/`,
      root `Makefile`, root `requirements.txt` (via `git rm`)
- [x] Created `examples/README.md` (default content repo + bring-your-own)
- [x] Fixed doc/config drift:
      - `vllm-statefulset.yaml` comment ("TP=2") corrected to describe TP = node GPU count
      - `infra/README.md` "~11s to ~11s" typo removed
      - genericized brand strings (demo domain / institution) out of infra README, tf, scripts
- [x] Reframed root `README.md` to the platform
- [x] Gate: `grep -rni "burnersite|stanford"` clean except `PLATFORM-PLAN.md` (the spec itself)
- [x] CHANGELOG Phase 1 entry added
- [x] Committed

Notes / decisions made this phase:
- `terraform/variables.tf`: `domain` default → `""`, `cert_email` default → `""`
  (consistent with the locked no-domain-default decision; full DNS gating is Phase 4).
- `generate-pods.sh` `HOST` default → `""` (now expected to be passed explicitly /
  from `terraform output -raw base_host`).
- `print-access-cards.sh` title is a static generic string (its heredoc is quoted, so
  env-var templating wouldn't expand there).

---

### Phase 3: Generic image + clone-at-startup — DONE (2026-06-05)
- [x] `infra/images/workspace/startup.sh`: clones $CONTENT_REPO (init+fetch, handles SHAs),
      best-effort pip install (venv → --user fallback), exec code-server. Degrades if git/
      python3 absent. Works as ENTRYPOINT and as stock-image command override.
- [x] Dockerfile bakes no content (code-server + python3 + git + startup.sh ENTRYPOINT).
- [x] workspace-pod-template.yaml: command override + workspace-startup ConfigMap volume/mount.
- [x] generate-pods.sh emits workspace-startup-configmap.yaml from canonical startup.sh
      (indented into a literal block); applied with the rest of generated/.
- [x] build-image.sh → build-workspace-image.sh (optional, content-free build).
- [x] Verified: bash -n all; generate-pods round-trips → ConfigMap parses, embedded startup.sh
      is valid bash, pod command+volume wired; helm + terraform regression clean.
- [x] Docs: infra/README file tree + image paths; CHANGELOG Phase 3.

Decisions this phase:
- **Single canonical startup.sh** at infra/images/workspace/. No duplicate in the chart —
  generate-pods.sh reads it and emits the ConfigMap (no kubectl --from-file needed).
- ConfigMap path is authoritative for BOTH image modes (command override always set), so
  the stock and prebuilt images behave identically. Phase 8 uses the stock image.
- startup.sh uses `set -uo pipefail` (NOT -e) so a clone/pip hiccup never blocks code-server.

## NEXT: Phase 8 (the ONLY remaining work) — run the e2e on REAL LKE

All code is done (Phases 1–7 committed). The single remaining task is running the already-
built `infra/scripts/e2e-smoke.sh` once a VALID Linode token is available — see the
"⛔ Phase 8 BLOCKED" section above for the exact commands. Do it in ONE session; the script
always tears down. Then add the README "Verified end-to-end" note + final CHANGELOG entry.

Nothing else is outstanding. Do NOT re-do Phases 1–7.

## Blockers
- None for Phases 1–7.
- Phase 8 needs `TF_VAR_token` (or `LINODE_TOKEN`) exported, else write BLOCKED note + STOP.
