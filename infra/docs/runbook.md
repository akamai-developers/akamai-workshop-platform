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
writes `infra/manifests/generated/access-cards.csv` and starts the student join portal.
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

Put `https://join.<base-host>/present.html` on the classroom screen. The page shows the
join URL and a QR code generated in the browser. Try signing up with an unused email;
make sure the workspace opens in a new tab. That test claims a real slot. Reset it
before students arrive using the procedure below. Once you've opened the workspace,
deleting its registration is not enough.

The PocketBase admin username is `admin@workshop.local`. To get its generated password:

```bash
kubectl -n <ns> get secret join-portal-admin \
  -o jsonpath='{.data.PB_ADMIN_PASSWORD}' | base64 -d; echo
```

Use `https://join.<base-host>/_/` to fix a mistyped email or name. Only delete a
registration if nobody has used its workspace. Otherwise, run the reset below.

Keep the original cards ready as a fallback:

```bash
./scripts/print-access-cards.sh           # → infra/manifests/generated/access-cards.html
```

Print the HTML or keep `access-cards.csv` available to the instructor.

## T+0: Class begins

Students scan the QR code, enter their name and email, and get a workspace. They
log into code-server/Jupyter with the password shown on the join page. If they
return later from another device, entering the same email brings back the same
assignment. Inference is reached at
`http://vllm:8000/v1` from inside the workspace.

## Reclaim a used workspace

If someone claimed a slot by mistake but **never opened the workspace**, an instructor
can delete the registration at `https://join.<base-host>/_/`. If they used the
workspace, don't delete the registration directly. Its password, browser session,
files, agent, or bucket may still belong to that student.

Use the deployment checkout containing `infra/kubeconfig.yaml` and the gitignored
`infra/manifests/generated/` state. Preview the reset first, then confirm it:

```bash
python3 infra/scripts/reset-student.py --slot s01
python3 infra/scripts/reset-student.py --slot s01 --confirm
```

The command marks the registration **resetting**, so the portal stops handing out
that slot. It removes the old workspace, rotates its password, restores the
workshop baseline, and releases the slot only after those steps succeed. In scoped
mode, it rebuilds the student's namespace, including their agent and dedicated
vLLM configuration. It also removes that student's model-cache PVC, so the model
may need to download again. For managed Object Storage, it empties the student's
bucket and rotates only their key. Shared vLLM stays up for everyone else.
This command cannot reset external inference.

This permanently deletes the student's work. Don't run it while they're still
working. If a step fails, the registration stays blocked (`resetting=true`). Fix
the reported problem, reconcile generated state with the live Secrets if needed,
and rerun the command. Don't delete the registration by hand until you've checked
the workspace, storage, and credentials. The reset needs the original generated
state and operator kubeconfig; neither is stored in Git.

Email is not verified. After a reset, someone can enter the same email and claim
the newly available slot again. If that's a problem for your workshop, use
stronger identity checks or instructor approval.

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
| Portal unavailable | Check its Deployment, PVC, and Ingress using the [troubleshooting steps](troubleshooting.md#the-join-portal-is-unavailable); use cards if needed |
| Student mistyped email | Correct the record at `https://join.<base-host>/_/`; delete only an unused accidental claim |
| All workspaces down | Check CPU nodes: `kubectl get nodes` |
| No GPU capacity at deploy | Retry another region / smaller plan — see [sizing.md](sizing.md) |
| Total infra failure | Fall back to a local model (e.g. Ollama on the instructor's laptop) |

`<ns>` is the namespace (`workshop` by default).
