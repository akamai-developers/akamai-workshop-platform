# akamai-workshop-platform — front door for the deploy wizard.
# `make deploy` is interactive; pass ARGS=... for flags / non-interactive runs.
#
#   make deploy
#   make deploy ARGS="--yes --config config.yaml"
#   make dry-run ARGS="--students 80 --model Qwen/Qwen3-8B-FP8"
#   make teardown
#   make capacity-test ARGS="--model Qwen/Qwen3-8B-FP8"

ARGS ?=

.PHONY: deploy teardown capacity-test dry-run models sizing-selftest help

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

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n",$$1,$$2}'
