# Classroom-day runbook

A timeline for running a class of **N students**. Times are relative to class start
(`T+0`); compress them for a small class. Cold start (cluster + GPU operator + model
download) is ~15–20 min, so you don't need to provision hours early. GPU nodes bill by the
hour — see [cost.md](cost.md).

## T-1h to T-20m: Deploy

```bash
export TF_VAR_token="your-linode-api-token"

# Preview the plan + cost without creating anything:
./deploy.sh --dry-run --students N --model Qwen/Qwen3-8B-FP8

# Deploy (interactive prompts + cost confirm), or headless with a config:
make deploy
#   or: ./deploy.sh --yes --config config.yaml
```

The wizard provisions the LKE cluster (CPU + GPU pools), gpu-operator, ingress-nginx
(+ NodeBalancer), the vLLM StatefulSet, wildcard TLS, and the per-student workspaces, then
writes `infra/manifests/generated/access-cards.csv` and deploys the self-service join portal.
Expect node counts to match the sizing preview (e.g. 80 students → 5 GPU + 5 CPU nodes).

## T-15m: Validate

```bash
./scripts/health-check.sh        # vLLM ready, /health 200, a test completion returns text
```

Optionally measure real capacity for this model + content (see [sizing.md](sizing.md)):

```bash
make capacity-test ARGS="--students N"
```

## T-10m: Smoke-test one workspace

1. Open `https://s01.<base-host>/` in a browser (`<base-host>` is printed at the end of
   deploy and in `access-cards.csv`). In no-domain mode the cert is self-signed: **accept the
   browser warning once**, then code-server and its WebSockets work.
2. Log in with the password from `access-cards.csv`.
3. Confirm the content repo cloned into the workspace and that a call to
   `http://vllm:8000/v1` from a terminal in the workspace returns a completion.

Re-running `generate-pods.sh` is idempotent — existing passwords in `access-cards.csv` are
preserved, bumping `-n` only mints passwords for new students. Use `--rotate` to mint fresh
passwords for everyone (e.g. between cohorts); the previous CSV is archived to `.bak`.

## T-5m: Prepare student check-in

Open `https://join.<base-host>/present.html` on the classroom screen. It displays the shared
join URL and a locally rendered QR code. Test a registration with an unused email and verify
that the assigned workspace opens in a new tab. This consumes a real slot. Before students
arrive, reclaim it with the per-slot reset below; do not merely delete a registration after
opening its workspace.

The PocketBase administrator is `admin@workshop.local`. Retrieve its generated password with:

```bash
kubectl -n <ns> get secret join-portal-admin \
  -o jsonpath='{.data.PB_ADMIN_PASSWORD}' | base64 -d; echo
```

Use `https://join.<base-host>/_/` to correct a mistyped email or name. Delete a registration
only if the workspace was never used; a used workspace needs the reset procedure below.

Keep the original cards ready as a fallback:

```bash
./scripts/print-access-cards.sh           # → infra/manifests/generated/access-cards.html
```

Open the HTML and print, or keep `access-cards.csv` available to the instructor.

## T+0: Class begins

Students scan the shared QR code, enter their name and email, and receive their workspace.
They then log into code-server/Jupyter with the displayed workspace password. Re-entering the
same email restores the assignment from any device. Inference is reached at
`http://vllm:8000/v1` from inside the workspace.

## Reclaim a used workspace

For an accidental claim that was **never opened**, an instructor can delete its PocketBase
registration at `https://join.<base-host>/_/`. Once a student has used the workspace, do not
delete the registration directly: its password, browser session, files, agent, or bucket
may still belong to the previous student.

From the deployment checkout with `infra/kubeconfig.yaml` and the gitignored
`infra/manifests/generated/` state, inspect one slot and then confirm its destructive reset:

```bash
python3 infra/scripts/reset-student.py --slot s01
python3 infra/scripts/reset-student.py --slot s01 --confirm
```

The command marks the registration **resetting** so the portal cannot return that slot,
removes the old workspace, rotates its password, restores the workspace baseline, and only
then deletes the registration to make the slot available. In scoped mode it rebuilds the
entire student's namespace, including their agent and dedicated vLLM configuration. Its
model-cache PVC is also removed; allow for a cold model download. Managed Object Storage
is emptied and only that student's key is rotated. Shared vLLM is deliberately **not**
restarted, because other students use it. External inference cannot be reset here.

This permanently removes the student's work. Do not run it while they are still working.
If any step fails, the registration stays blocked (`resetting=true`); fix the reported
problem, reconcile generated state with the live Secrets if necessary, and rerun the command.
Do not manually delete the registration until the
workspace, storage, and credentials have been verified clean. This procedure requires the
original generated state and the operator kubeconfig; neither is stored in Git.

Email remains an unverified identifier: after release, someone entering the same email
could claim the now-free slot again. If that must be prohibited, use stronger identity or
an instructor approval gate.

## T+end: Tear down (stops billing)

```bash
make teardown            # or ./deploy.sh teardown
linode-cli lke clusters-list   # verify nothing lingers
```

## Emergency procedures

| Scenario | Action |
|---|---|
| vLLM pod crash | `kubectl -n <ns> rollout restart statefulset/vllm` |
| Student can't connect | `kubectl -n <ns> get pod ws-NN` (and see [troubleshooting.md](troubleshooting.md)) |
| Portal unavailable | Inspect the named Deployment, PVC, and Ingress with the commands in [troubleshooting](troubleshooting.md#the-join-portal-is-unavailable); cards remain the fallback |
| Student mistyped email | Correct the record at `https://join.<base-host>/_/`; delete only an unused accidental claim |
| All workspaces down | Check CPU nodes: `kubectl get nodes` |
| No GPU capacity at deploy | Retry another region / smaller plan — see [sizing.md](sizing.md) |
| Total infra failure | Fall back to a local model (e.g. Ollama on the instructor's laptop) |

`<ns>` is the namespace (`workshop` by default).
