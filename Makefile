COMPOSE := docker compose
CPU     := -f compose.yaml -f compose.cpu.yaml

.PHONY: help up cpu-up urls down restart logs ps models gpu shell pull register clean

help: ## Show available targets
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

up: ## Start the stack (GPU, unless COMPOSE_FILE pins CPU mode)
	$(COMPOSE) up -d
	@$(MAKE) --no-print-directory urls

cpu-up: ## Start the stack without the GPU (one-off; see COMPOSE_FILE in .env to persist)
	$(COMPOSE) $(CPU) up -d
	@$(MAKE) --no-print-directory urls
	@echo "CPU-only applies to this command only. To make it stick for every target,"
	@echo "uncomment COMPOSE_FILE in .env."

urls: ## Print the actual published URLs
	@echo "UI:  http://$$($(COMPOSE) port open-webui 8080)"
	@echo "API: http://$$($(COMPOSE) port ollama 11434)"

down: ## Stop and remove containers (models and chat history are kept)
	$(COMPOSE) down

restart: ## Restart both services
	$(COMPOSE) restart

logs: ## Follow logs from both services
	$(COMPOSE) logs -f

ps: ## Show service status
	$(COMPOSE) ps

models: ## List installed models
	$(COMPOSE) exec ollama ollama list

gpu: ## Verify GPU passthrough into the container
	$(COMPOSE) exec ollama nvidia-smi

shell: ## Open a shell inside the ollama container
	$(COMPOSE) exec ollama bash

pull: ## Update both images to their latest builds
	$(COMPOSE) pull

register: ## Register Modelfiles from the model dir (e.g. GLM-Config)
	./scripts/register-modelfiles.sh

clean: ## Remove containers and the compose network only. Never touches model weights.
	$(COMPOSE) down --remove-orphans
