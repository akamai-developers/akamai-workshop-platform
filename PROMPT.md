# Autonomous Build — akamai-workshop-platform

## CRITICAL: This is a multi-session build. ALWAYS do this first.

Before doing ANYTHING else, assess the current state of the project:

1. Read **`BUILD_PROGRESS.md`** in this repo (if it exists) to see what's been completed.
2. Read **`PLATFORM-PLAN.md`** — it is the complete, authoritative blueprint. Every
   design decision is locked there. Do NOT re-decide anything; implement it.
3. Run `ls -la`, `git branch --show-current`, and
   `find infra -type f | sort` to see current state.
4. Check the wizard/syntax still work:
   `bash -n deploy.sh 2>/dev/null; ls infra/helm 2>/dev/null; (cd infra/terraform && terraform validate 2>/dev/null)`

Based on what you find, pick up where the last session left off. Do NOT redo work
that already exists and is correct. Move to the next incomplete task.

**After every phase, update `BUILD_PROGRESS.md`** with: what you completed (checkmarks),
what remains, any blockers, and the exact next step. This file is your handoff.

---

## ⚠️ SAFETY — READ EVERY SESSION (this build spends real money)

Phase 8 provisions **real Akamai/LKE infrastructure that bills by the hour** (GPU
nodes, a NodeBalancer, block storage). The following rules are absolute:

1. **Phase 8 must run start-to-finish in ONE session and ALWAYS tear down.** Never end
   a session with a live cluster. Teardown must happen even if a test fails — use the
   `trap ... EXIT` mechanism in `infra/scripts/e2e-smoke.sh` (you will build it).
2. **Smoke test uses the cheapest possible footprint:** 1× `g2-gpu-rtx4000a1-s`
   (~$0.52/hr), smallest model `Qwen/Qwen3-4B-Instruct-2507`, 1 CPU node, 1 student,
   no domain (sslip.io + self-signed), TP=1. NEVER the 80-student config for testing.
3. **Phases 1–7 cost nothing** (code only). Only Phase 8 deploys. Do not run
   `terraform apply` outside Phase 8's smoke script.
4. After teardown, **verify with `linode-cli lke clusters-list`** that the test cluster
   is gone. If anything lingers, delete it before ending the session.
5. **NEVER commit secrets** — passwords, kubeconfig, tfvars, certs, tokens. They are
   gitignored; keep them that way. Use `git add <specific files>`, never `git add -A`.

If `TF_VAR_token` (or `LINODE_TOKEN`) is not set, do Phases 1–7 fully, then in Phase 8
write a clear "BLOCKED: export TF_VAR_token then re-run" note in BUILD_PROGRESS.md and
STOP — do not fake the deploy.

---

## The Mission

Convert this repo from a single AI-agents *workshop* into **`akamai-workshop-platform`**:
a content-agnostic, self-service platform that spins up per-student browser code-servers
+ GPU vLLM inference on Akamai LKE, with one interactive wizard to deploy and one command
to tear down. A user answers ~5 questions ("80 students, this model, no domain") and gets
a running classroom + a CSV of student URLs/passwords. The platform discovers GPU regions
live, sizes the GPUs automatically (with an empirical capacity-test), works with or without
a domain, and never leaves a billing cluster stranded.

End state: a clean infra-first repo whose `./deploy.sh` wizard provisions, tests, and
(via `./deploy.sh teardown`) destroys a working classroom — proven by an end-to-end
smoke test against real LKE in Phase 8.

## Context You Need

1. **`PLATFORM-PLAN.md`** is the spec. Read it fully before each phase. Key sections:
   §1 decisions · §2 wizard UX + inputs · §3 sizing formula + GPU decode · §4 model
   catalog · §5 domain-optional · §6 restructure + couplings (file:line) · §6.5 region
   & capacity · §7 build phases.
2. **Read the existing `infra/`** — most pieces exist and just need parameterizing.
   `terraform/*.tf`, `scripts/{provision,generate-pods,issue-cert,teardown}.sh`,
   `manifests/{vllm-statefulset,workspace-pod-template,networkpolicy}.yaml`,
   `images/workspace/Dockerfile`. Do not rewrite what works — parameterize it.
3. The workspace image **already clones content from an external repo** at build time —
   that is why the local `workshop/ src/ docs/ extend/ reference/` folders are duplicates
   to be cut.

---

## Tech Stack

- **IaC**: Terraform (Linode provider) — install locally to `~/bin` if missing (no root).
- **Orchestration**: Kubernetes (LKE), `kubectl`, Helm-style templating for manifests.
- **Wizard**: POSIX `bash` (`deploy.sh`) + a `Makefile` front door. Python3 for the
  sizing calculator and the live GPU-region/capacity lookups (stdlib only — `urllib`,
  `json`; `linode-cli` and `jq` are available too).
- **Inference**: vLLM (`vllm/vllm-openai`), OpenAI-compatible.
- **Workspaces**: `codercom/code-server` (stock image for the smoke test via a
  ConfigMap startup script; dedicated prebuilt image produced as code, publish is manual).
- **TLS**: `openssl` self-signed wildcard (no-domain) or `lego` + Linode DNS-01 (domain).
- **No new heavy deps. No web UI. No operator/CRD.** The plan warns against overbuilding —
  the whole product is: one config + a wizard with two verbs + a sizing/capacity helper.

---

## Architecture

```
                 ./deploy.sh (wizard)  ──reads──►  config.yaml / flags
                        │
            ┌───────────┴────────────┐
            ▼                        ▼
   sizing calculator         live GPU region+capacity check (Linode API)
   (students+model→plan)      (capabilities + availability + preflight)
            │                        │
            └───────────┬────────────┘
                        ▼
                 terraform apply  ──► LKE: CPU pool + GPU pool + ingress + (DNS|sslip.io)
                        ▼
                 vLLM StatefulSet (model, TP, replicas = values)
                        ▼
                 generate-pods.sh ──► per-student code-server + Ingress + password
                        ▼
                 access-cards.csv  (sNN.<host> + password)

  Student browser ──HTTPS──► ingress-nginx ──► ws-NN (code-server, clones content_repo)
                                                  └──► http://vllm:8000/v1  (NetworkPolicy-gated)
```

Full detail (sizing math, domain modes, capacity fallbacks) is in `PLATFORM-PLAN.md`.

---

## Documentation Requirements

**Update docs EVERY phase, not at the end.**

1. **README.md** (root) — reframe to the platform: what it is, prerequisites, the
   `./deploy.sh` quick start (no-domain path first), the input set, cost note, teardown.
2. **CHANGELOG.md** — dated entry per phase (Keep a Changelog format).
3. **`infra/docs/`** — `quickstart.md`, `architecture.md`, `sizing.md` (with the GPU-name
   decode + formula), `cost.md`; genericize `runbook.md` from "80 students/burnersite.xyz".

### Docs checklist (after EVERY phase)
- [ ] README quick start commands are accurate for what exists now
- [ ] CHANGELOG has a dated entry for this phase
- [ ] No references to `burnersite.xyz`, "Stanford", or a hardcoded 80 remain in touched files

---

## Build Order

> Phases map to `PLATFORM-PLAN.md §7`. Each is one session, independently verifiable.
> Phases 1–7 are code-only (free). Phase 8 is the real deploy+test+teardown.

### Phase 1: Foundation & cleanup  (plan phase 0)
- [ ] Create and switch to branch `rebuild/akamai-workshop-platform` (do NOT build on `main`).
- [ ] Cut the duplicate teaching content: remove `workshop/`, `src/`, `docs/` (root),
      `extend/`, `reference/`, root `Makefile`, root `requirements.txt`.
- [ ] Create `examples/README.md` pointing at the default content repo
      (`github.com/akamai-developers/ai-agents-workshop`) and explaining "bring your own
      content repo via `content_repo:`".
- [ ] Fix the doc/config drift called out in PLATFORM-PLAN.md §6:
      `infra/manifests/vllm-statefulset.yaml:12` comment ("TP=2") vs arg (`--tensor-parallel-size=4`);
      `infra/README.md` "~11s to ~11s" typo; genericize "80 students / s01–s80 / burnersite.xyz / Stanford".
- [ ] Reframe root `README.md` to the platform (placeholder quick start is fine this phase).
- [ ] Verify: `git status` shows only intended deletions/additions; `grep -ri "burnersite\|stanford" --include=*.md --include=*.tf --include=*.sh .` returns nothing in non-archived files.
- [ ] **Docs:** root README reframed; CHANGELOG.md started with Phase 1 entry.
- [ ] Commit.

### Phase 2: Parameterize the infra  (plan phase 1)
- [ ] Introduce `infra/helm/` (Helm chart OR a simple `envsubst`/template layer — keep it
      light) so these are **values**, not hardcodes: `model`, `tensor_parallel_size`,
      `replicas`, `namespace`, `image`, `student_count`, `max_model_len`, `gpu_memory_util`.
- [ ] Wire the matching Terraform variables (region, cpu/gpu node types + counts, label,
      domain, subdomain_prefix). Most exist — fix defaults and the tfvars example.
- [ ] Fix the must-fix couplings in PLATFORM-PLAN.md §6 (vllm model + TP, workspace image
      ref, namespace, generate-pods defaults).
- [ ] Verify: `helm template infra/helm --set model=X --set tensor_parallel_size=1`
      renders valid YAML (or the template script does); `cd infra/terraform && terraform validate`.
- [ ] **Docs:** README + CHANGELOG; start `infra/docs/architecture.md`.
- [ ] Commit.

### Phase 3: Generic image + clone-at-startup  (plan phase 3)
- [ ] Write `infra/images/workspace/startup.sh` that is **image-agnostic**: clones
      `CONTENT_REPO` (default ai-agents-workshop) into the workspace, runs
      `pip install -r requirements.txt` if present, then starts code-server with `PASSWORD`,
      `VLLM_HOST`, `MODEL_NAME` from env. It must work BOTH as the entrypoint of the
      dedicated image AND as a `command:` override on the stock `codercom/code-server` image
      (this is what Phase 8 uses — no Docker needed).
- [ ] Rewrite `infra/images/workspace/Dockerfile` to bake **no content** — just
      code-server + python3 + git + `startup.sh`. Content arrives at pod startup.
- [ ] Update `workspace-pod-template.yaml` to mount `startup.sh` via ConfigMap and set
      `CONTENT_REPO`; make the image reference a value.
- [ ] Keep `build-image.sh` as `infra/scripts/build-workspace-image.sh` — an OPTIONAL
      advanced path; document that publishing the image needs Docker + a registry login.
- [ ] Verify (no Docker): `bash -n startup.sh`; render the pod template and confirm the
      ConfigMap + command wiring is valid via `kubectl apply --dry-run=client -f -`.
- [ ] **Docs:** README + CHANGELOG; note the prebuilt-image vs stock-image paths.
- [ ] Commit.

### Phase 4: Domain-optional + region/capacity preflight  (plan phase 2 + §6.5)
- [ ] Make `domain` the single knob (PLATFORM-PLAN.md §5): empty ⇒ sslip.io self-signed;
      set ⇒ Linode DNS + lego. Gate `data.linode_domain` + `linode_domain_record.*` on
      `count = var.domain == "" ? 0 : 1`. Add a `base_host` Terraform output
      (`<lb-ip-dashed>.sslip.io` vs `<prefix>.<domain>`). TLS secret name stays
      `workshop-tls` in both modes.
- [ ] Self-signed wildcard: generate `*.<lb-ip>.sslip.io` cert via `openssl` and store as
      the `workshop-tls` secret when no domain. `issue-cert.sh`: early-exit when DOMAIN empty.
- [ ] Add `infra/scripts/regions.sh` (or python): list LIVE GPU-capable regions
      (`/v4/regions` capability filter) and check plan availability (`/v4/regions/availability`),
      per §6.5. Add a **capacity preflight** the wizard runs BEFORE full provision:
      validate/attempt the GPU pool first; on capacity failure, surface the 3 fallbacks
      (retry region / smaller plan / request capacity) and FAIL CLEAN (no half-built cluster).
- [ ] **Non-goal — keep vLLM private (PLATFORM-PLAN.md §5.5):** do NOT add an ingress route,
      LoadBalancer/NodePort, or `--api-key` for vLLM. It stays `ClusterIP` + default-deny
      NetworkPolicy; the only ingress routes are the per-student code-servers. Off-cluster
      access is `kubectl port-forward` only.
- [ ] Verify: `terraform validate` with `domain=""` AND with `domain="example.com"`;
      `regions.sh` prints the live GPU region list; `openssl` cert generates + loads as a secret YAML.
- [ ] **Docs:** `infra/docs/sizing.md` (GPU decode + formula) and a region/capacity note.
- [ ] Commit.

### Phase 5: The wizard  (plan phase 4)
- [ ] Build `./deploy.sh` (interactive) + a `Makefile` front door (`make deploy`,
      `make teardown`, `make capacity-test`). Flow per PLATFORM-PLAN.md §2:
      collect students/model/content_repo/domain/region → look up model in the catalog (§4,
      ungated only, default `Qwen/Qwen3-8B-FP8`) → run the sizing formula (§3) → print a
      **cost + sizing preview** (hourly × nodes) → one confirm → write `terraform.tfvars` +
      helm values → `provision.sh` → `generate-pods.sh` → print `access-cards.csv`.
- [ ] Add a **non-interactive mode** (`./deploy.sh --yes --config config.yaml` or env vars)
      so Phase 8 can drive it headless. Provide `config.example.yaml`.
- [ ] Encode the sizing calculator as a small Python module the wizard calls (students+model
      → replicas, gpu_node_type+TP, gpu_node_count, cpu_node_count, $/hr). Include the
      worked example from §3 as a self-test.
- [ ] Verify (no spend): `./deploy.sh --dry-run --students 80 --model Qwen/Qwen3-8B-FP8`
      prints the correct plan (5× g2-gpu-rtx4000a4-s, 5 CPU nodes, ~$17.80/hr) and writes
      NO cloud resources. Sizing self-test passes.
- [ ] **Docs:** `infra/docs/quickstart.md`, `infra/docs/cost.md`; README quick start now real.
- [ ] Commit.

### Phase 6: Capacity-test  (plan phase 5)
- [ ] Generalize `infra/manifests/load-test-job.yaml` + `scripts/load-test.sh` into
      `infra/scripts/capacity-test.sh` + a parametric Job: deploy 1 replica, ramp
      concurrency, record p50/p99 latency + tokens/sec, report **students-per-replica** at a
      p99 threshold. Two profiles: generic agent-chat (default) and workshop-aware
      (replay the content repo's example prompts).
- [ ] Wire `make capacity-test` and a wizard "test capacity first" branch that feeds the
      measured number back into sizing.
- [ ] Verify (no spend): `bash -n capacity-test.sh`; the Job manifest renders and
      `kubectl apply --dry-run=client` passes; the report formatter prints a sample.
- [ ] **Docs:** README + CHANGELOG; capacity-test usage in sizing.md.
- [ ] Commit.

### Phase 7: Docs & genericization audit  (plan phase 6)
- [ ] Finalize `infra/docs/{quickstart,architecture,sizing,cost,runbook,security,troubleshooting}.md`.
      Genericize runbook to "N students". Ensure the GPU-name decode and the formula are in sizing.md.
- [ ] **Document laptop / off-cluster inference access via `kubectl port-forward`** in
      quickstart.md (the snippet in PLATFORM-PLAN.md §5.5). This is the ONLY supported
      off-cluster access. Do NOT document or imply a public inference URL.
- [ ] Root README: full, accurate quick start (no-domain first), input table, model menu,
      cost + teardown, "bring your own content".
- [ ] Verify: `grep -rი "burnersite\|stanford\|TODO\|FIXME" infra docs README.md` is clean;
      every command in the README quick start is real and present.
- [ ] **Docs audit + final CHANGELOG entry.**
- [ ] Commit.

### Phase 8: END-TO-END deploy + test + teardown on REAL LKE  (acceptance gate)
> Prerequisite: `TF_VAR_token` (or `LINODE_TOKEN`). If absent, write BLOCKED note + STOP.
> This is the ONLY phase that spends money. Run it fully in one session. ALWAYS tear down.

- [ ] Ensure `terraform` is installed (download the linux_amd64 binary to `~/bin` if missing).
      `export TF_VAR_token="${TF_VAR_token:-$LINODE_TOKEN}"`.
- [ ] Build `infra/scripts/e2e-smoke.sh` with **guaranteed teardown**:
      ```
      trap 'echo "[e2e] tearing down..."; ./deploy.sh teardown --yes || (cd infra/terraform && terraform destroy -auto-approve)' EXIT
      ```
      It deploys the **cheapest** config headless and asserts each step:
      `students=1`, `model=Qwen/Qwen3-4B-Instruct-2507`, `gpu_node_type=g2-gpu-rtx4000a1-s`,
      `gpu_node_count=1`, `tensor_parallel_size=1`, 1 small CPU node, `domain=""` (sslip.io),
      and workspace pods using the **stock `codercom/code-server` image + ConfigMap startup.sh**
      (no Docker/registry needed), label the cluster `awp-e2e-smoke`.
- [ ] Run it and verify the full chain:
      1. `terraform apply` succeeds; a node reports `nvidia.com/gpu`.
      2. vLLM pod Ready; `/health` 200; a chat completion (via port-forward or `kubectl exec`)
         returns non-empty text.
      3. Student workspace Ready; `https://s01.<lb-ip-dashed>.sslip.io/` returns the
         code-server login page (`curl -k`, expect HTTP 200 + code-server markup).
      4. From inside the workspace pod, `POST http://vllm:8000/v1/chat/completions` returns a
         completion (proves student→vLLM path through the NetworkPolicy).
      5. `capacity-test.sh` runs and emits a students-per-replica number.
      6. **Teardown ran** (via trap): `linode-cli lke clusters-list` shows no `awp-e2e-smoke`
         cluster; no leftover NodeBalancer/volumes for it.
- [ ] Record the actual measured numbers (cold-start time, capacity result, total $ if
      derivable) in `BUILD_PROGRESS.md` and a short `infra/docs/e2e-results.md`.
- [ ] If any assertion fails: capture logs, ensure teardown still happened, write the failure
      + root cause to BUILD_PROGRESS.md, and (if fixable in code) loop back to fix and re-run.
- [ ] **Docs:** README "Verified end-to-end" note + CHANGELOG final entry.
- [ ] Commit (NEVER commit kubeconfig, tfvars, certs, generated/ , access-cards.csv).

### When all 8 phases are done
Write a final `BUILD_PROGRESS.md` summary: every phase checked, the e2e result, and the
exact `./deploy.sh` command a real user runs. Then stop the loop (do not re-provision).

---

## Commit Rules

- Commit after each phase; work on branch `rebuild/akamai-workshop-platform`.
- Never mention Claude, Anthropic, or AI in commit messages.
- Never commit `CLAUDE.md`, `.claude/`, `PROMPT.md`, `BUILD_PROGRESS.md`, `build-logs/`.
- **NEVER commit secrets:** kubeconfig, `terraform.tfvars`, `infra/.certs/`,
  `infra/manifests/generated/` (contains student passwords), `access-cards.csv`,
  `secret.yaml`, API tokens. All are gitignored — keep them so.
- Before every commit run `git diff --cached` and scan for anything resembling a token,
  password, or key. If found, unstage it immediately.
- Use `git add <specific files>` — NEVER `git add .` or `git add -A`.
