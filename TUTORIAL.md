# Tutorial — understanding and operating this stack

A learning-oriented guide to the `ollama-server` project: how it is put together, which settings
matter and why, and how to add and test a new model.

`README.md` is the lookup reference — commands, troubleshooting, quick answers. This document
explains. Every number and transcript below was measured on this machine (RTX 4060 Laptop, 8 GB
VRAM, WSL2), not copied from documentation.

---

## 1. How the setup works

Two containers, one job each.

```
  your browser                    ┌───────────────────────────────┐
  http://localhost:3000  ───────► │ open-webui   (port 8080)      │
                                  │  chat UI, accounts, history,  │
                                  │  model manager, RAG           │
                                  └──────────────┬────────────────┘
                                                 │  http://ollama:11434
                                                 │  (internal docker network)
  your code / curl                ┌──────────────▼────────────────┐
  http://localhost:11434 ───────► │ ollama       (port 11434)     │
                                  │  loads weights, runs inference│
                                  └──────────────┬────────────────┘
                                                 │  CUDA
                                  ┌──────────────▼────────────────┐
                                  │  RTX 4060 Laptop — 8188 MiB   │
                                  └───────────────────────────────┘
```

**Why two containers.** Ollama is a model server with no interface; Open WebUI is an interface
with no model server. Keeping them separate means you can restart, reset, or delete the UI
without touching 17 GB of weights — and you can point your own code straight at Ollama, ignoring
the UI entirely.

**Two ways in, and they are not the same.**

- The **UI** reaches Ollama at `http://ollama:11434` — a hostname that only resolves *inside* the
  compose network. It never uses the published port.
- **You** reach Ollama at `http://localhost:11434`, the published port. From Windows too: WSL2
  forwards localhost automatically.

That distinction matters: if you set `BIND_ADDR` to something unreachable, the UI keeps working
while your scripts break — because they use different paths.

**Who owns what.**

| Container | Owns | Stored at |
|---|---|---|
| `ollama` | model weights, manifests, the SSH identity | `/home/mehmet/ollama_models` → `/root/.ollama` |
| `open-webui` | accounts, chat history, per-model settings, RAG index | `./data/open-webui` → `/app/backend/data` |

Both are bind mounts, so both survive `make down`, container recreation, and image upgrades.

**Startup order is enforced.** `compose.yaml` gives `ollama` a healthcheck (`ollama list`) and
makes `open-webui` wait for `condition: service_healthy`. The UI never comes up pointing at a
model server that isn't ready.

---

## 2. The commands you actually use

```bash
make up        # start everything
make ps        # is it healthy?
make urls      # what ports did it actually publish?
make models    # what's installed
make logs      # follow both services (Ctrl-C to stop)
make down      # stop. Models and chat history are kept.
```

Healthy looks like this:

```
NAME         STATUS
ollama       Up 2 hours (healthy)
open-webui   Up 39 minutes (healthy)
```

Use `make urls` rather than assuming port 3000 — it reads the real mapping back from Docker, so
it stays correct after you change a port:

```
UI:  http://127.0.0.1:3000
API: http://127.0.0.1:11434
```

`make down` is safe. It removes containers, not data. The only destructive act available to you
is deleting `./data` or `/home/mehmet/ollama_models` by hand.

---

## 3. Every setting in `.env`

Copy `.env.example` to `.env` and edit. Compose reads it automatically; your shell environment
overrides it if set.

### Storage

| Setting | Current | What it does |
|---|---|---|
| `OLLAMA_MODELS_DIR` | `/home/mehmet/ollama_models` | Host directory holding all weights, mounted at `/root/.ollama`. Point it elsewhere to use a different disk. Contents are root-owned — do not `chown` it. |

### Networking

| Setting | Current | What it does |
|---|---|---|
| `BIND_ADDR` | `127.0.0.1` | Interface for the Ollama API. `0.0.0.0` exposes it to your LAN — **Ollama has no authentication**, so anyone on the network could use your GPU. |
| `WEBUI_BIND_ADDR` | `127.0.0.1` | Same for the UI. Safer to expose, since the UI has accounts. |
| `OLLAMA_PORT` | `11434` | Published API port. |
| `WEBUI_PORT` | `3000` | Published UI port. Change if something else owns 3000. |

To reach the UI from your phone but keep the API private: `WEBUI_BIND_ADDR=0.0.0.0`, leave
`BIND_ADDR=127.0.0.1`.

### Image versions

| Setting | Current | What it does |
|---|---|---|
| `OLLAMA_TAG` | `latest` | Ollama image. Currently 0.20.0. |
| `OPEN_WEBUI_TAG` | `v0.11.1` | **Pinned deliberately.** The rolling `main`/`latest` tags crash on startup with a circular import that breaks the database migration, leaving the container restart-looping on `no such table: config`. Bump only after checking upstream fixed it. |

### Runtime tuning — the ones that matter on 8 GB

| Setting | Current | What it does |
|---|---|---|
| `OLLAMA_CONTEXT_LENGTH` | `8192` | Default context window. **The single most VRAM-sensitive knob** — see §8. |
| `OLLAMA_MAX_LOADED_MODELS` | `1` | How many models stay resident. On 8 GB, `1` is correct: a second model evicts the first anyway, so a higher value just causes reload thrash. |
| `OLLAMA_KEEP_ALIVE` | `5m` | How long a model stays in VRAM after its last request. Then it is evicted and the VRAM is returned. Reload costs ~2 s. Raise it if you query in bursts; lower it if you need the GPU for other work. |

You can watch `KEEP_ALIVE` work — `ollama ps` is empty after five idle minutes, and
`nvidia-smi` drops to ~476 MiB.

### Authentication

| Setting | Current | What it does |
|---|---|---|
| `WEBUI_AUTH` | `True` | Keeps accounts on. The first account created becomes admin, and **admin rights are what unlock model management**. Setting `False` gives a single shared session with no login. |

After editing `.env`, run `make up` — Compose recreates only what changed.

---

## 4. Settings that live in the UI, not in `.env`

Some things cannot be set from a file; they live in Open WebUI's database under `./data`.

**The first account is the admin.** It is a local account in a local SQLite database — the email
and password never leave your machine.

**Function Calling — the one you still need to set.** Open WebUI always attaches its built-in
tools (`time`, `user_input`) to every request, and for any model it has no record of, it assumes
all capabilities are available. Old models with no tool template reject the request outright:

```
registry.ollama.ai/library/llama2:latest does not support tools    (HTTP 400)
```

Fix, per affected model:

> Profile menu → **Admin Panel** → **Settings** → **Models** → click the model →
> **Advanced Params** → click **Function Calling** until it reads **Legacy** → **Save**

> ⚠️ The control cycles **Default → Native → Legacy**, and the backend treats *anything that is
> not Legacy* — including the one labelled "Default" — as native tool calling. Landing on
> "Default" leaves the bug in place. You must land on **Legacy**.

On this machine that applies to `llama2`, `tinyllama`, and both LFM2 models. It does **not**
apply to `qwen3:4b`, the `glm-*` models, or `llama3.2:1b` — they support tools natively and
should be left alone.

**What a `./data` wipe costs.** These per-model settings, your account, and all chat history
live there. Weights do not. Deleting `./data` means recreating the admin account and re-applying
these toggles — but no re-downloading.

---

## 5. Adding a model — four routes

### Route A — the Open WebUI admin panel

> Profile menu → **Admin Panel** → **Settings** → **Models** → type a tag in the pull field
> (e.g. `llama3.2:3b`) → download

Progress shows inline. Best when you are already in the browser and want a model immediately.
Browse tags at [ollama.com/library](https://ollama.com/library).

### Route B — the CLI

```bash
docker compose exec ollama ollama pull llama3.2:1b
```

Prefer this when scripting, when you want honest progress output, or when the download is large
enough that you would rather not hold a browser tab open.

`make pull-models` is the batch form of exactly this call: it loops the same
`ollama pull` over the `MODELS` list in the `Makefile` (`llama3.2:1b qwen3:4b` by default, or
`make pull-models MODELS="gemma3:4b"` for a one-off). That is what brings a fresh clone up to a
working baseline in one command — the single-model invocation above stays the right choice when
you already know the one tag you want.

### Route C — HuggingFace GGUF

Any GGUF on HuggingFace works directly:

```bash
docker compose exec ollama ollama pull hf.co/<user>/<repo>:<quant>
```

This is how the two LFM2 models on this machine arrived:

```
hf.co/LiquidAI/LFM2-VL-3B-GGUF:F16           6.0 GB
hf.co/LiquidAI/LFM2-1.2B-Extract-GGUF:F16    2.3 GB
```

**Choosing a quant on 8 GB.** The tag after `:` is the quantization — how many bits per weight.
Lower means smaller and faster, with some quality loss.

| Quant | Size vs F16 | Use it when |
|---|---|---|
| `F16` / `BF16` | 100% | The model is tiny (≤3B) and you want maximum fidelity. |
| `Q8_0` | ~50% | Small models. `llama3.2:1b` ships this way. |
| `Q4_K_M` | ~27% | **The default choice for 7-8B on this card.** `qwen3:4b` uses it. |
| `Q3` and below | <25% | Only to squeeze in a model that otherwise will not fit; quality drops noticeably. |

Rule of thumb: weights must leave room for the KV cache. A model whose file is ~5 GB will not
comfortably run at a large context on an 8 GB card.

### Route D — a custom Modelfile

To save tuned parameters as a reusable model. The existing `GLM-Config` in the models directory:

```
FROM glm-ocr
PARAMETER num_ctx 16384
PARAMETER num_thread 6
PARAMETER num_predict 8192
PARAMETER temperature 0
PARAMETER top_p 0.00001
PARAMETER top_k 1
PARAMETER repeat_penalty 1.1
```

`FROM` names the base model; each `PARAMETER` bakes in a default. Temperature 0 with `top_k 1`
makes it deterministic — sensible for OCR, wrong for creative writing.

Drop a Modelfile at the root of `/home/mehmet/ollama_models`, then:

```bash
make register
```

It becomes a model named after the file, lowercased (`GLM-Config` → `glm-config`), and appears in
the UI dropdown. Re-running skips anything already registered, so it is safe to repeat.

---

## 6. Worked example — adding `llama3.2:1b` for real

Every command and every output below is a real transcript from this machine.

**Pull it.**

```bash
$ docker compose exec ollama ollama pull llama3.2:1b
...
writing manifest
success
```

**Check what you got, before using it.**

```bash
$ docker compose exec ollama ollama show llama3.2:1b
  Model
    architecture        llama
    parameters          1.2B
    context length      131072
    quantization        Q8_0

  Capabilities
    completion
    tools
```

`tools` is present — so this model works with Open WebUI's defaults and needs no Legacy toggle.
That is the difference between it and `llama2`, which is the same family but three years older.

**Talk to it.**

```bash
$ curl -s localhost:11434/api/chat -d '{
    "model":"llama3.2:1b",
    "messages":[{"role":"user","content":"Name three primary colors, one short line."}],
    "stream":false}' | python3 -c 'import json,sys;print(json.load(sys.stdin)["message"]["content"])'

Red Blue Green
```

**Confirm it is on the GPU.**

```bash
$ docker compose exec ollama ollama ps
NAME           ID              SIZE      PROCESSOR    CONTEXT
llama3.2:1b    baf6a787fdff    2.2 GB    100% GPU     8192
```

`100% GPU` is what you want. Anything like `30%/70% CPU/GPU` means it did not fit.

**Measure it honestly.** Short replies produce meaningless rates — load overhead swamps the
measurement. A 3-token reply measured 21.6 tok/s; the same model on a 126-token reply:

```
llama3.2:1b      126 tokens   134.6 tok/s
qwen3:4b         160 tokens    67.6 tok/s
```

Twice the speed of the 4B, as expected for a third of the parameters. Always measure on a
generation of at least ~100 tokens.

**Note the eviction.** Running `qwen3:4b` immediately after removed `llama3.2:1b` from
`ollama ps` — `OLLAMA_MAX_LOADED_MODELS=1` means one resident model at a time. Not an error.

---

## 7. Testing any new model — the checklist

Run these five in order. Each one rules out a class of problem.

```bash
M=llama3.2:1b        # the model you just added

# 1. What can it do? tools / vision / thinking
docker compose exec ollama ollama show $M | sed -n '/Capabilities/,/^$/p'

# 2. Does it answer at all?
curl -s localhost:11434/api/chat \
  -d "{\"model\":\"$M\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hi\"}],\"stream\":false}"

# 3. Did it fit on the GPU?  Must read 100% GPU
docker compose exec ollama ollama ps

# 4. How fast, on a real-length generation?
curl -s localhost:11434/api/chat \
  -d "{\"model\":\"$M\",\"messages\":[{\"role\":\"user\",\"content\":\"Write a 120-word paragraph about the sea.\"}],\"stream\":false,\"options\":{\"num_predict\":160}}" \
  | python3 -c 'import json,sys;d=json.load(sys.stdin);print("%.1f tok/s"%(d["eval_count"]/(d["eval_duration"]/1e9)))'

# 5. Does it work through the UI too?
#    Open http://localhost:3000, pick it from the dropdown, send a message.
```

Interpreting the results:

| Symptom | Meaning | Action |
|---|---|---|
| `does not support tools` (400) | No tool template | Set Function Calling → **Legacy** (§4) |
| `ollama ps` shows CPU % | Did not fit in VRAM | Lower `num_ctx`, or use a smaller quant |
| Very low tok/s but `100% GPU` | Measured on too short a reply | Re-measure with ~100+ tokens |
| Reasoning text inside the answer | Thinking model, mis-configured | See §9 |

---

## 8. Sizing for 8 GB

Context length is the setting that will bite you. Measured on `qwen3:4b`, same model, only
`num_ctx` changed:

| `num_ctx` | Resident size | Placement | VRAM free | Speed |
|---|---|---|---|---|
| **8192** (default) | 4.1 GB | **100% GPU** | 3730 MiB | 68.8 tok/s |
| 32768 | 7.8 GB | 8% CPU / 92% GPU | 544 MiB | — |
| 131072 | 23 GB | 70% CPU / 30% GPU | 716 MiB | 20.5 tok/s |

Raising context to the model's full 262144 would need far more memory than the card has. The KV
cache grows with context and lives in VRAM alongside the weights, so context is not free.

**The 3.4× slowdown** from 68.8 to 20.5 tok/s is what "spilling to CPU" costs. `ollama ps` losing
`100% GPU` is your warning light.

Per-request override, without touching `.env`:

```json
{"model":"qwen3:4b","messages":[...],"options":{"num_ctx":16384}}
```

Rough guidance for this card: a 7-8B model at Q4_K_M with 8192 context fits comfortably. Beyond
that, either the model or the context has to shrink.

---

## 9. Gotchas that cost real time

**`think: false` makes qwen3 output worse, not cleaner.** Counter-intuitive, and measured:

| Request | `thinking` field | `content` | Tokens |
|---|---|---|---|
| `"think": true` (and the default) | the reasoning | `"4"` — clean | 275 |
| `"think": false` | empty | reasoning spills into the answer as prose | 44 |
| `/no_think` in the prompt | short | `"4"` — clean | 73 |

`think: false` does not stop the model reasoning; it stops Ollama *separating* the reasoning out,
so it lands in `content`. Leave `think` at its default and read `message.content`. To genuinely
cut reasoning on qwen3, append `/no_think` to the prompt — 73 tokens instead of 264 on the same
question.

**"Default" is not a safe value for Function Calling.** Covered in §4; it is the single most
misleading control in the UI.

**Old models are not just weaker — they are differently shaped.** `llama2` and `llama3.2:1b` are
the same family; the 2024 one supports tools and the 2023 one cannot, and no setting changes
that. Check `ollama show` before assuming.

**A short generation cannot measure speed.** 21.6 vs 134.6 tok/s for the same model on the same
hardware, differing only in reply length.

**What survives what:**

| Action | Weights | Chats & settings |
|---|---|---|
| `make down` / `make up` | kept | kept |
| Container recreation, image upgrade | kept | kept |
| Deleting `./data` | kept | **lost** |
| Deleting `/home/mehmet/ollama_models` | **lost** | kept |

---

## Where to go next

- `README.md` — command reference and troubleshooting.
- [ollama.com/library](https://ollama.com/library) — model catalogue.
- `docker compose exec ollama ollama show <model>` — the fastest way to understand any model you
  are about to rely on.
