# akamai-workshop-platform — front door for the deploy wizard.
# `make deploy` is interactive; pass ARGS=... for flags / non-interactive runs.
#
#   make deploy
#   make deploy ARGS="--yes --config config.yaml"
#   make deploy ARGS="--config examples/own-inference.yaml"   # a composed workshop
#   make deploy ARGS="--config examples/sa-agent.yaml"
#   make dry-run ARGS="--students 80 --model Qwen/Qwen3-8B-FP8"
#   make teardown
#   make capacity-test ARGS="--model Qwen/Qwen3-8B-FP8"
#   make verify-default                       # default path intact (helm golden + sizing)
#   make verify-config CONFIG=examples/sa-agent.yaml   # validate a config via dry-run

ARGS ?=
CONFIG ?=

.PHONY: deploy teardown capacity-test dry-run models sizing-selftest verify-default verify-config help

deploy: ## Provision a classroom (interactive unless ARGS add --yes/--config)
	./deploy.sh deploy $(ARGS)

dry-run: ## Print the sizing/cost plan; create nothing
	./deploy.sh deploy --dry-run $(ARGS)

teardown: ## Destroy all classroom infrastructure
	./deploy.sh teardown $(ARGS)

capacity-test: ## Measure students-per-replica for a model (Phase 6)
	./deploy.sh capacity-test $(ARGS)

models: ## List the ungated model catalog
	python3 infra/scripts/sizing.py catalog

sizing-selftest: ## Run the sizing calculator self-test
	python3 infra/scripts/sizing.py selftest

verify-default: ## Prove the default path is intact (helm golden + sizing self-test)
	@helm template infra/helm | diff - .build/golden/default-helm.yaml >/dev/null \
	  && echo "  ✓ default helm output matches the golden snapshot" \
	  || { echo "  ✗ default helm output DIFFERS from .build/golden/default-helm.yaml"; exit 1; }
	@python3 infra/scripts/sizing.py selftest >/dev/null \
	  && echo "  ✓ sizing self-test passed" \
	  || { echo "  ✗ sizing self-test FAILED"; exit 1; }

verify-config: ## Validate a config via dry-run (CONFIG=path/to/config.yaml)
	@test -n "$(CONFIG)" || { echo "usage: make verify-config CONFIG=examples/sa-agent.yaml"; exit 2; }
	./deploy.sh deploy --dry-run --config $(CONFIG)

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n",$$1,$$2}'
