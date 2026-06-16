# Developer / verification guide

How to set up the local toolchain and run the offline gates that guard the
component-based extensions (PLAN.md). None of this is needed to *operate* the
platform — it is for contributors changing the templates, scripts, or sizing.

## Toolchain (macOS)

```bash
brew install helm kind shellcheck yamllint kubeconform bats-core coreutils
brew install cilium-cli            # not a core formula
```

`coreutils` provides `gtimeout` (the e2e smoke's spend cap). Confirm everything:

```bash
for t in helm kind kubeconform bats shellcheck yamllint cilium gtimeout; do
  command -v "$t" >/dev/null && echo "ok $t" || echo "MISSING $t"
done
docker info >/dev/null && echo "docker ok"
```

## Offline gates (no cloud, no GPU)

These run on every change and are the backbone of verification:

```bash
# 1. Default output must stay byte-identical (the #1 invariant).
helm template infra/helm | diff - .build/golden/default-helm.yaml

# 2. Schema-validate any flag combination.
helm template infra/helm --set <flag>=<value> | kubeconform -strict -ignore-missing-schemas

# 3. Lint.
shellcheck <changed>.sh
yamllint <changed>.yaml            # config in .yamllint.yaml (repo style)

# 4. Unit tests against fake linode-cli / curl shims.
bats tests/bats/

# 5. Sizing calculator self-test.
python3 infra/scripts/sizing.py selftest
```

Note: `kubeconform` **skips** CRD-typed objects (e.g. Gateway API). For new
CRD-typed manifests also run `kubectl --context kind-awp apply --dry-run=server`
(the kind cluster has the CRDs).

## kind + Cilium (NetworkPolicy / RBAC enforcement tests)

LKE ships Cilium, which *enforces* NetworkPolicy — an unenforced policy is silently
decorative, so isolation tests must run on a CNI that enforces. The kind config
mirrors that (Cilium CNI, Cilium replaces kube-proxy):

```bash
kind create cluster --config tests/kind-cluster.yaml   # name: awp
cilium install --wait && cilium status --wait
tests/cilium-enforcement-check.sh   # positive control then default-deny → proves enforcement
```

The Phase-3 isolation tests reuse this cluster: they prove A→B connectivity works,
then that a per-namespace NetworkPolicy blocks it, and that a scoped kubeconfig is
`Forbidden` for cluster-scoped reads / other namespaces but allowed in its own.

## Recapturing the golden snapshots

Only after an *intended* default-behaviour change:

```bash
mkdir -p .build/golden
helm template infra/helm > .build/golden/default-helm.yaml
# masked per-student render (passwords are random, so they are masked):
infra/scripts/generate-pods.sh -n 2 --host fixed.example   # writes infra/manifests/generated/
# then mask the Secret `password:` field and the CSV password column into
# .build/golden/default-pods.masked.yaml (see make verify-default).
```
