# ollama-server

Ollama + [Open WebUI](https://github.com/open-webui/open-webui) in Docker Compose. Chat with
local models and download new ones from the browser — no CLI required.

**New here?** Read [TUTORIAL.md](TUTORIAL.md) — it explains how the stack fits together, what
every setting does, and how to add and test a model. This file is the quick reference.

## Quick start

```bash
cp .env.example .env    # already done; edit if you want different ports
make up
```

Then open **http://localhost:3000**.

The **first account you create becomes the admin.** It's a local account in a local database —
the email and password are never sent anywhere. Admin rights are what unlock model management.

## Version pinning

`OPEN_WEBUI_TAG` is pinned to `v0.11.1` in `.env`, deliberately. The rolling `main`/`latest`
tags (identical digests) currently crash on startup with a circular import in
`open_webui/config.py` that breaks the Alembic migration, so the database is never created and
the container restart-loops on `no such table: config`. `v0.11.1` is the last stable release
before that regression, and is also the fallback baked into `compose.yaml`, so a fresh clone
with no `.env` still starts. When upstream fixes it, bump the tag in `.env` and `make up`.

`OLLAMA_TAG` is `latest`, which is fine — that image was already on this machine and works.

## Downloading models from the UI

Profile menu (bottom left) → **Admin Panel** → **Settings** → **Models** → enter a model tag in
the pull field (e.g. `llama3.2:3b`, `qwen2.5-coder:7b`, `gemma3:4b`) and hit download. Progress
shows inline. New models land in `/home/mehmet/ollama_models` alongside the ones you already
have and appear in the chat model dropdown immediately.

Browse available tags at [ollama.com/library](https://ollama.com/library).

Older models (roughly pre-2024) have no tool-calling template and will fail on first message
with `does not support tools` until you flip one setting — see *Model does not support tools*
under Troubleshooting.

## What's where

| | |
|---|---|
| Model weights | `/home/mehmet/ollama_models` (your existing 17 GB dir, mounted at `/root/.ollama`) |
| Chats, accounts, settings | `./data/open-webui` |
| Web UI | http://localhost:3000 |
| Ollama API | http://localhost:11434 |

The two data locations are deliberately separate: you can wipe `./data` to reset the UI without
putting a single byte of downloaded model at risk.

## Commands

```
make up           Start the stack (GPU)
make cpu-up       Start without the GPU (one-off)
make urls         Print the actual published URLs
make down         Stop containers (models and history are kept)
make logs         Follow logs
make ps           Service status
make models       List installed models
make pull-models  Download the baseline model set (MODELS="a b" to override)
make gpu          Verify GPU passthrough (nvidia-smi inside the container)
make shell        Shell inside the ollama container
make pull         Update both images
make register     Register Modelfiles (e.g. GLM-Config) as named models
make clean        Remove containers and network. Never touches model weights.
```

`make pull-models` downloads model *weights*; `make pull` updates the two container *images*.

## Using the API from your own code

The API is bound to localhost on port 11434, so anything on this machine — and Windows-side
tools, via WSL2 port forwarding — can reach it:

```bash
curl http://localhost:11434/api/generate -d '{"model":"qwen3:4b","prompt":"hi","stream":false}'
```

It also speaks the OpenAI wire format at `http://localhost:11434/v1` (any API key string works),
so OpenAI SDKs work by changing only the base URL.

Code running *inside* this compose network should use `http://ollama:11434` instead.

## Modelfiles

`GLM-Config` in the model dir is a Modelfile, not a registered model. `make register` turns it
(and any other Modelfile at the root of that dir) into a real model named after the file —
`GLM-Config` becomes `glm-config` — which then shows up in the UI dropdown. Re-running it skips
anything already registered.

The script identifies a Modelfile by validating the whole file (first instruction must be
`FROM`, every instruction must be one Ollama recognises) rather than grepping for a `FROM`
line. That matters because this directory also holds the Ollama CLI's `history` file and your
SSH keys, and a loose grep would happily try to register those as models.

## Notes for this machine (RTX 4060 Laptop, 8 GB VRAM)

- 8 GB fits roughly a 7–8B model at Q4 with a normal context, fully on the GPU. Bigger models
  still run, but layers spill to CPU and generation slows sharply.
- `OLLAMA_MAX_LOADED_MODELS=1` is deliberate: on 8 GB, keeping two models resident causes
  constant eviction and reloading.
- Raising `OLLAMA_CONTEXT_LENGTH` raises VRAM use per model. 8192 is a safe default; drop it if
  a model that used to fit starts offloading to CPU.
- `make gpu` is the fastest way to confirm the GPU is actually visible to the container.

## Exposing to other devices

Set both `BIND_ADDR` and `WEBUI_BIND_ADDR` to `0.0.0.0` in `.env` and `make restart`. Only do
this on a network you trust — Ollama's API has no authentication of its own. To expose just the
UI (which does have accounts) and keep the API private, set `WEBUI_BIND_ADDR=0.0.0.0` and leave
`BIND_ADDR=127.0.0.1`.

## Troubleshooting

**`<model> does not support tools` (HTTP 400, chat fails immediately)** — e.g.
`registry.ollama.ai/library/llama2:latest does not support tools`. The model has no tool-calling
template, but Open WebUI attached tools to the request anyway, and Ollama rejects the whole call.

It is not a broken install. Open WebUI always attaches its built-in `time` and `user_input`
tools, and for any model it has no record of, every capability defaults to *enabled* — so it
sends a native `tools` field to a model that cannot accept one. The request fails before the
model is even loaded.

Fix, per affected model:

> Profile menu → **Admin Panel** → **Settings** → **Models** → click the model →
> **Advanced Params** → click **Function Calling** until it reads **Legacy** → **Save**

Then start a **new** chat — the setting is applied when a message is sent, so an existing failed
chat is not a reliable test.

⚠️ **"Default" is not a safe value here.** The control cycles Default → Native → Legacy, and
Open WebUI treats *anything that is not Legacy* — including Default — as native tool calling.
You must land on **Legacy** explicitly.

Which models need it on this machine:

| Supports tools (leave alone) | Needs **Legacy** |
|---|---|
| `qwen3:4b`, `glm-ocr`, `glm-ocr-optimized`, `glm-config` | `llama2`, `tinyllama`, `hf.co/LiquidAI/LFM2-VL-3B-GGUF:F16`, `hf.co/LiquidAI/LFM2-1.2B-Extract-GGUF:F16` |

Check any model yourself with `docker compose exec ollama ollama show <model>` and read the
**Capabilities** section — if `tools` is absent, it needs Legacy.

Do *not* set Legacy on the tool-capable models: they would lose native function calling for no
benefit. The setting lives in `./data/open-webui`, so it survives restarts — but wiping that
directory means re-applying these toggles by hand.

**Models missing from the dropdown** — check the mount resolved: `make models` should list them.
If it's empty, `OLLAMA_MODELS_DIR` in `.env` is pointing somewhere else.

**`could not select device driver`** — the NVIDIA container runtime isn't reachable. Use
`make cpu-up` to keep working, and check `docker info | grep -i nvidia`.

Note that `cpu-up` is a one-off: a later `make up` recreates `ollama` **with** the GPU
reservation and reproduces the failure. To stay on CPU across every target, uncomment
`COMPOSE_FILE=compose.yaml:compose.cpu.yaml` in `.env` — Compose reads it from there, so
plain `make up` then runs CPU-only too.

**Port already in use** — change `WEBUI_PORT` or `OLLAMA_PORT` in `.env`, then `make up`
(or `make cpu-up` if you are on CPU). `make urls` always prints the ports actually published,
read back from Docker rather than guessed.

**Open WebUI is slow to become ready on first start** — it initializes its database and
downloads an embedding model for RAG on the first boot. `make logs` shows progress. Docker may
briefly report it `unhealthy` during this window; that is just the image's own health probe
running before the app has bound its port.

**`open-webui` restart-loops with `no such table: config`** — you are on a broken upstream
build. See *Version pinning* above; pin `OPEN_WEBUI_TAG` to a known-good release.

**UI API returns `{"detail":"Not authenticated"}`** — expected. `WEBUI_AUTH=True`, so the
proxied endpoints need a logged-in session. Create the first account in the browser.
