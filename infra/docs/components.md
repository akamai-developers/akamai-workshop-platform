# Components

A workshop is a set of per-student components. A preset picks a combination for you. This page lists the components, shows how to set them by hand, and covers the two features large classes need: the model mirror and the 100-node pool limit.

## The catalog

With no preset, the platform provisions its original shape: one code-server per student and one shared vLLM. Every component below defaults to that behavior, so a deploy that sets none of them matches the original platform.

| Component | Values (default first) | Controls |
|---|---|---|
| `editor` | `code-server`, `jupyter` | The workspace UI |
| `inference` | `shared-vllm`, `dedicated-vllm`, `external` | Where the model comes from. `dedicated-vllm` needs `cluster_access: scoped`. `external` needs `--inference-endpoint <url>` and takes an optional `--inference-api-key` |
| `gpus_per_student` | `1` | GPUs per student for `dedicated-vllm` |
| `predownload_models` | empty | `dedicated-vllm` only. Comma-separated models pulled into each student's volume at startup, so switching the served model restarts from cache instead of downloading again |
| `model_mirror_bucket` | empty | `dedicated-vllm` only. Sync models from an Object Storage mirror instead of Hugging Face. Set automatically when `infra/model-mirror.conf` exists |
| `gpu_sharing` | `none`, `timeslicing` | NVIDIA time-slicing so two vLLMs share one card. Needs `dedicated-vllm`. See [gpu-sharing.md](gpu-sharing.md) |
| `gpu_timeslicing_replicas` | `2` | Logical GPUs advertised per card when time-slicing is on. Must be 2 or more |
| `cluster_access` | `none`, `scoped` | A namespace, a scoped kubeconfig, and a NetworkPolicy per student, so students can run kubectl from their notebook |
| `object_storage` | `none`, `managed` | A bucket and a bucket-scoped key per student, on an E3 endpoint |
| `object_storage_region` | the cluster region | Region for the managed buckets. It must have an E3 endpoint, for example `us-ord`. Buckets never go to `us-sea`. A `us-sea` cluster uses `us-ord` unless you set this |
| `agent_deploy` | `none`, `plain` | Lets the student ship their agent to their own namespace. Needs `cluster_access: scoped` |

Set them in `config.yaml`:

```yaml
editor:           jupyter
inference:        dedicated-vllm
cluster_access:   scoped
```

```bash
./deploy.sh --config config.yaml
# or as flags: ./deploy.sh --editor jupyter --inference dedicated-vllm --cluster-access scoped
```

`config.example.yaml` lists every key with a comment.

## The presets as config files

The three presets live in [`examples/`](../../examples/) as plain config files, so you can copy one and change a line:

```bash
./deploy.sh --config examples/own-inference.yaml    # same as --preset own-inference
./deploy.sh --config examples/sa-agent.yaml         # same as --preset solution-architect-agent
```

Check a config without creating anything:

```bash
make verify-config CONFIG=examples/own-inference.yaml
```

When `cluster_access: scoped` or `object_storage: managed` is on, each access card also names the student's namespace and says that their kubeconfig or bucket is already wired into the workspace. No secret material is printed on the card.

## Model mirror

With `dedicated-vllm`, every student's vLLM downloads its models at startup. Past a few dozen students, Hugging Face rate-limits the downloads and pods sit in `SlowDown` retries. Seed a mirror in Object Storage once, and every pod syncs from the bucket instead:

```bash
make mirror-models ARGS="--bucket <globally-unique-name> --region us-ord"
```

The command creates the bucket on an E3 endpoint, uploads the models, mints a read-only key, and writes `infra/model-mirror.conf`. The next `./deploy.sh` reads that file and sets `model_mirror_bucket` for you. The mirror region must have an E3 endpoint, and `us-sea` is refused.

## Classes over 100 students

LKE caps a node pool at 100 nodes. The platform splits the GPU pool into pools of 100 or fewer that share the `pool=gpu` label, so a 200-student `dedicated-vllm` class fits in one cluster.

## Design notes

[`PLAN.md`](../../PLAN.md) holds the component-model design. [`dev.md`](dev.md) covers the verification gates, including `make verify-default`, which proves a deploy with no components set still renders the original platform byte for byte.
