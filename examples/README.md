# Workshop content

`akamai-workshop-platform` is **content-agnostic**. It provisions the classroom —
per-student browser IDEs (code-server), GPU vLLM inference, URLs, passwords, TLS, and
networking on Akamai LKE — and clones your teaching content into each student's
workspace at pod startup. The content lives in its own repo, not here.

## Default content

If you don't specify a content repo, the platform clones:

> **https://github.com/akamai-developers/ai-agents-workshop**

A 1-hour hands-on workshop where students build an AI agent (tools, MCP, memory,
autonomous reasoning) against the platform's vLLM endpoint.

## Bring your own content

Point the wizard at any public git repo:

```bash
./deploy.sh            # the wizard prompts: "Workshop content repo? [ai-agents]"
```

or set it non-interactively:

```yaml
# config.yaml
content_repo: "https://github.com/your-org/your-workshop"
```

At pod startup each workspace runs `startup.sh`, which:

1. `git clone $CONTENT_REPO` into the student's home directory,
2. runs `pip install -r requirements.txt` if the repo has one,
3. starts code-server with the student's password and the in-cluster
   inference endpoint (`VLLM_HOST`, `MODEL_NAME`) wired in.

### What makes a good content repo

- A `requirements.txt` at the root (optional) — installed automatically.
- Self-contained exercises that read `VLLM_HOST` / `MODEL_NAME` from the environment
  so they target the platform's vLLM endpoint (`http://vllm:8000/v1`) with no edits.
- No secrets committed; students each get their own workspace and password.
