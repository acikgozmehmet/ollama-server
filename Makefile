COMPOSE := docker compose
CPU     := -f compose.yaml -f compose.cpu.yaml

# Model set pulled by `make pull-models`. Both are tool-capable and fit 8 GB.
# `?=` so both override forms work — `MODELS="a b" make pull-models` and
# `make pull-models MODELS="a b"` — matching the env-prefix idiom `make register`
# already uses for OLLAMA_MODELS_DIR. The recipe rejects an empty MODELS, so
# neither form can quietly pull nothing and still report success.
# Keep the pull-models help text below in sync with these names.
MODELS  ?= llama3.2:1b qwen3:4b

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show available targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

# --- Stack --------------------------------------------------------------------

.PHONY: up
up: ## Start the stack (GPU, unless COMPOSE_FILE pins CPU mode)
	$(COMPOSE) up -d
	@$(MAKE) --no-print-directory urls

.PHONY: cpu-up
cpu-up: ## Start the stack without the GPU (one-off; see COMPOSE_FILE in .env to persist)
	$(COMPOSE) $(CPU) up -d
	@$(MAKE) --no-print-directory urls
	@echo "CPU-only applies to this command only. To make it stick for every target,"
	@echo "uncomment COMPOSE_FILE in .env."

.PHONY: urls
urls: ## Print the actual published URLs
	@echo "UI:  http://$$($(COMPOSE) port open-webui 8080)"
	@echo "API: http://$$($(COMPOSE) port ollama 11434)"

.PHONY: down
down: ## Stop and remove containers (models and chat history are kept)
	$(COMPOSE) down

.PHONY: restart
restart: ## Restart both services
	$(COMPOSE) restart

.PHONY: ps
ps: ## Show service status
	$(COMPOSE) ps

.PHONY: logs
logs: ## Follow logs from both services
	$(COMPOSE) logs -f

# --- Models -------------------------------------------------------------------

.PHONY: models
models: ## List installed models
	$(COMPOSE) exec ollama ollama list

.PHONY: pull-models
pull-models: ## Download model weights: llama3.2:1b qwen3:4b (override: MODELS="a b")
	@[ -n "$(MODELS)" ] || { echo "MODELS is empty — nothing to pull"; exit 1; }
	@id=$$($(COMPOSE) ps -q ollama) || exit 1; \
	[ -n "$$id" ] || { echo "ollama is not running — run 'make up' first"; exit 1; }
	@for m in $(MODELS); do \
		echo "==> pulling $$m"; \
		$(COMPOSE) exec ollama ollama pull $$m || exit 1; \
	done
	@$(MAKE) --no-print-directory models

.PHONY: register
register: ## Register Modelfiles from the model dir (e.g. GLM-Config)
	./scripts/register-modelfiles.sh

# --- Maintenance --------------------------------------------------------------

.PHONY: gpu
gpu: ## Verify GPU passthrough into the container
	$(COMPOSE) exec ollama nvidia-smi

.PHONY: shell
shell: ## Open a shell inside the ollama container
	$(COMPOSE) exec ollama bash

.PHONY: pull
pull: ## Update both container images to their latest builds
	$(COMPOSE) pull

.PHONY: clean
clean: ## Remove containers and the compose network only. Never touches model weights.
	$(COMPOSE) down --remove-orphans
