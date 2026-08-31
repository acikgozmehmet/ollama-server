#!/usr/bin/env bash
# Register loose Modelfiles that live in the Ollama data dir as named models,
# so their tuned parameters survive container rebuilds.
#
# Each Modelfile at the root of $OLLAMA_MODELS_DIR becomes a model named after
# the file, lowercased. GLM-Config -> glm-config.
set -euo pipefail

cd "$(dirname "$0")/.."

# Load .env WITHOUT clobbering values already set in the environment. This
# matches Docker Compose precedence (shell environment wins over .env), so
# `OLLAMA_MODELS_DIR=/mnt/models make up && make register` scans the same
# directory that actually got mounted.
if [ -f .env ]; then
  while IFS='=' read -r key value || [ -n "$key" ]; do
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    [ -n "$value" ] || continue
    [ -n "${!key:-}" ] || export "$key=$value"
  done < .env
fi

MODELS_DIR="${OLLAMA_MODELS_DIR:-/home/mehmet/ollama_models}"

if ! docker compose ps --status running --services | grep -q -x ollama; then
  echo "ollama container is not running. Start it with 'make up' first." >&2
  exit 1
fi

# Decide whether a file is a Modelfile by validating ALL of it, not just one
# line: the first instruction must be FROM, and every instruction must be one
# Ollama recognises. Grepping for a single "FROM" line is not enough - the
# Ollama CLI's `history` file shares this directory and its first line is often
# prose like "from the following text, extract ...", which would otherwise be
# registered as a junk model.
is_modelfile() {
  awk '
    BEGIN {
      split("from parameter template system adapter license message", k, " ")
      for (i in k) valid[k[i]] = 1
      ok = 0; bad = 0; first = 1; in_block = 0
    }
    {
      if (in_block) { if (gsub(/"""/, "&") % 2) in_block = 0; next }
      if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) next
      instr = tolower($1)
      # An awk `exit` runs END, so record the failure instead of
      # exiting with a status END would overwrite.
      if (!(instr in valid) || NF < 2) { bad = 1; exit }
      if (first) { if (instr != "from") { bad = 1; exit } ; ok = 1; first = 0 }
      if (gsub(/"""/, "&") % 2) in_block = 1
    }
    END { exit (bad || in_block || !ok) }
  ' "$1" 2>/dev/null
}

existing="$(docker compose exec -T ollama ollama list | tail -n +2 | awk '{print $1}')"
found=0

for f in "$MODELS_DIR"/*; do
  # Skip directories and files we cannot read (e.g. root-only SSH keys).
  [ -f "$f" ] && [ -r "$f" ] || continue
  is_modelfile "$f" || continue
  found=1

  base="$(basename "$f")"
  name="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"

  # Fixed-string comparison: a '.' or '-' in a filename must not act as a
  # regex metacharacter and produce a false "already registered" skip.
  if printf '%s\n' "$existing" | grep -F -x -q -e "$name" -e "$name:latest"; then
    echo "skip   ${name} (already registered)"
    continue
  fi

  echo "create ${name} from ${base}"
  # The dir is mounted at /root/.ollama inside the container.
  docker compose exec -T ollama ollama create "$name" -f "/root/.ollama/${base}"
done

[ "$found" -eq 1 ] || echo "No Modelfiles found in ${MODELS_DIR}"
