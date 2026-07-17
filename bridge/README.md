# The bridge (the brain)

`pz-bridge.mjs` reads the game's perception, asks an LLM what to do, writes the decision back, and serves the live mind dashboard at `http://localhost:8799/mind`. `llm.mjs` is the pluggable backend.

```bash
node pz-bridge.mjs
# → pz-bridge up on http://localhost:8799/mind — brain: <backend> (<model>) …
```

## Choose your AI

It works with **any** of these — free/local or hosted. Set a key (or `PZ_BACKEND`) and it auto-detects. Override the model with `PZ_MODEL`.

| Backend | How to enable | Default model | Notes |
|---------|---------------|---------------|-------|
| **Ollama** (free, local) | `PZ_BACKEND=ollama` | `llama3.1` | 100% free & offline. `OLLAMA_URL` default `http://localhost:11434`. Set `PZ_MODEL` to any pulled model (e.g. `mistral`, `qwen2.5`). |
| **Anthropic** (Claude) | `ANTHROPIC_API_KEY=…` | `claude-haiku-4-5` | Fast + cheap on Haiku. |
| **OpenAI** (GPT) | `OPENAI_API_KEY=…` | `gpt-4o-mini` | |
| **OpenAI-compatible** | `OPENAI_API_KEY=…` + `OPENAI_BASE_URL=…` | — | OpenRouter, Groq, Together, LM Studio, etc. Point `OPENAI_BASE_URL` at the endpoint. |
| **Google Gemini** | `GEMINI_API_KEY=…` | `gemini-1.5-flash` | |
| **Claude CLI** (default) | `claude` on PATH (or `CLAUDE_BIN`) | `haiku` | Uses your Claude Code subscription; no API key needed. |

### Examples

```bash
# Free & local with Ollama (pull a model first: `ollama pull llama3.1`)
PZ_BACKEND=ollama PZ_MODEL=llama3.1 node pz-bridge.mjs

# Anthropic API
ANTHROPIC_API_KEY=sk-ant-… PZ_MODEL=claude-haiku-4-5 node pz-bridge.mjs

# OpenAI
OPENAI_API_KEY=sk-… PZ_MODEL=gpt-4o-mini node pz-bridge.mjs

# OpenRouter (OpenAI-compatible) — try any model on one key
OPENAI_API_KEY=sk-or-… OPENAI_BASE_URL=https://openrouter.ai/api/v1 PZ_MODEL=meta-llama/llama-3.1-70b-instruct node pz-bridge.mjs

# Google Gemini
GEMINI_API_KEY=… PZ_MODEL=gemini-1.5-flash node pz-bridge.mjs
```

On Windows PowerShell, set vars with `$env:NAME="value"` before `node pz-bridge.mjs`. See [`.env.example`](.env.example).

## Tuning

| Var | Default | What |
|-----|---------|------|
| `PZ_MODEL` | per-backend | The model to use. |
| `PZ_TIMEOUT` | `45000` | Per-decision timeout (ms). Bump it for slow local models. |
| `PORT` (in file) | `8799` | Dashboard + intent port. |

**Speed matters.** The whole loop is more fun when decisions land in a few seconds. Small/fast models (Haiku, GPT-4o-mini, Gemini Flash, an 8B Ollama model) feel great. Big models are smarter but slower — the local reflex keeps the survivor alive either way, so favor speed.

## What it writes

- Reads `~/Zomboid/Lua/claude_percept.json` (the game's senses).
- Writes `~/Zomboid/Lua/claude_intent.txt` (the decision the mod executes).
- `pz-state.json` (next to the script) — the AI's persistent memory + decision log across restarts. Safe to delete for a clean slate.
