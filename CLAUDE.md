# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Docker Compose deployment of Ollama + Open WebUI for a single workstation (RTX 4060 Laptop,
8 GB VRAM, WSL2). There is no application source, no build, and no test suite — the
"codebase" is `compose.yaml`, `.env`, a `Makefile`, and one bash script. Changes are validated
by starting the stack and exercising it, not by CI.

Documentation is split deliberately: `README.md` is the lookup reference (commands,
troubleshooting), `TUTORIAL.md` is the explanatory guide (why each setting exists, measured
numbers from this machine). Keep that split when editing either.

## Commands

`make help` lists every target. The ones that matter:

```
make up        # start (GPU)
make cpu-up    # start without GPU — ONE-OFF, see below
make urls      # print the ports Docker actually published
make ps        # health status
make logs      # follow both services
make models    # ollama list
make gpu       # nvidia-smi inside the container — confirms GPU passthrough
make register  # register loose Modelfiles as named models
make down      # stop; all data kept
```

Verifying a model after adding one — the five-step checklist (capabilities, does it answer,
did it fit in VRAM, tok/s, does the UI path work) is in `TUTORIAL.md` §7. Step 3
(`docker compose exec ollama ollama ps` must read `100% GPU`) is the one that catches
VRAM overflow.

## Architecture

Two containers, one job each, wired by `compose.yaml`:

- `ollama` — inference server. Bind-mounts the pre-existing weight store
  `${OLLAMA_MODELS_DIR}` (default `/home/mehmet/ollama_models`) at `/root/.ollama`. Runs as
  root because that directory is root-owned; do not chown it.
- `open-webui` — chat UI, accounts, history, per-model settings, RAG index. Bind-mounts
  `./data/open-webui`. Waits on `condition: service_healthy` against ollama's `ollama list`
  healthcheck, so the UI never starts against a cold model server.

**The two data locations are separate on purpose.** Wiping `./data` resets the UI without
touching 17 GB of weights; the reverse is also true. Neither is in git (`data/` is ignored).
Per-model UI settings live in `./data`, so wiping it means re-applying them by hand.

**Two network paths, not interchangeable.** The UI reaches Ollama at `http://ollama:11434`
(compose-internal DNS, never the published port). Host code reaches it at
`http://localhost:11434` (the published port, also visible from Windows via WSL2 forwarding).
Anything written to run inside the compose network must use `ollama:11434`. Breaking
`BIND_ADDR` leaves the UI working while host scripts fail.

**Ollama's API has no authentication of its own.** Setting `BIND_ADDR=0.0.0.0` publishes an
unauthenticated inference API to the LAN. To reach the stack from another device, set only
`WEBUI_BIND_ADDR=0.0.0.0` (the UI has accounts) and leave `BIND_ADDR=127.0.0.1`.

## Things that will bite you

**`OPEN_WEBUI_TAG` is pinned to `v0.11.1` on purpose.** Do not bump it to `latest`/`main`:
those builds hit a circular import in `open_webui/config.py`, the Alembic migration never
runs, and the container restart-loops on `no such table: config`. The pin exists in both
`.env` and as the `compose.yaml` fallback so a fresh clone still starts. Only bump after
confirming upstream fixed it.

**`make cpu-up` is one-off.** A later `make up` recreates `ollama` *with* the GPU
reservation. To make CPU-only stick, uncomment `COMPOSE_FILE=compose.yaml:compose.cpu.yaml`
in `.env` — Compose reads that variable from the env file, and every `make` target then
inherits it. `compose.cpu.yaml` works by `!reset []` on the device reservations.

**Open WebUI's "Function Calling" control cycles Default → Native → Legacy, and anything
that is not Legacy means native.** Models without a tool template fail with
`does not support tools` (HTTP 400) because Open WebUI attaches its built-in tools by
default. The fix must land on **Legacy** explicitly; "Default" is not safe. Check a model
with `docker compose exec ollama ollama show <model>` and read Capabilities before
assuming. There is no host-side `ollama` binary — it exists only in the container.

**8 GB VRAM shapes the defaults.** `OLLAMA_MAX_LOADED_MODELS=1` prevents eviction thrash;
`OLLAMA_CONTEXT_LENGTH=8192` is only the *default* context for requests that don't specify
one — it is not a cap. A Modelfile `PARAMETER num_ctx` (which is what `GLM-Config` does) or a
per-request `options.num_ctx` overrides it upward and will spill layers to CPU. When
debugging GPU offload, check the model's own `num_ctx` before trusting this value.

## scripts/register-modelfiles.sh

Turns loose Modelfiles at the root of `${OLLAMA_MODELS_DIR}` into named models
(`GLM-Config` → `glm-config`), so tuned parameters survive container rebuilds.

Two pieces of its logic are load-bearing and were written against real failures — preserve
them if you touch the script:

- It validates the *whole* file (first instruction must be `FROM`, every instruction must be
  one Ollama recognises, `"""` blocks tracked) rather than grepping for a `FROM` line. That
  directory also holds the Ollama CLI's `history` file and SSH keys; a loose grep registers
  those as junk models.
- It loads `.env` without clobbering already-set environment variables, matching Compose
  precedence (shell environment wins). Note this only helps when the variable is actually
  exported: `OLLAMA_MODELS_DIR=... make register` applies the assignment to that one command,
  so a preceding `make up` with the same prefix does not carry over. Use
  `export OLLAMA_MODELS_DIR=...` to make the script scan the directory that was mounted.

## Conventions

- Every knob goes through `.env` with a fallback in `compose.yaml`, so the stack starts with
  no `.env` at all. Keep `.env.example` in sync — it carries the explanatory comments and is
  the only version in git.
- `.env`, `data/`, `*.gguf`, and `doc/*` are gitignored. `doc/` holds local session notes and
  is not shared.
- Makefile targets are self-documenting via `## ` comments, which `make help` parses.
