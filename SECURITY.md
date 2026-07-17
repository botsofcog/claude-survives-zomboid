# Security Policy

## Scope

Claude Survives runs entirely on your own machine. The bridge binds to `localhost:8799` only, and
the game ↔ brain link is two files in your `Zomboid/Lua/` folder. No data leaves your computer
except the prompts your chosen LLM backend sends to its provider (or nothing at all, if you use a
local Ollama model).

## Reporting a vulnerability

If you find a security issue — for example, a way the bridge could be reached from outside
localhost, or a prompt-injection path from game content into your LLM account — please **open a
private security advisory** on GitHub ("Security" tab → "Report a vulnerability") rather than a
public issue, and we'll respond as quickly as we can.

## Good practice for users

- Keep the bridge on `localhost`; don't expose port `8799` to your network.
- Use your own API keys and set them as environment variables, never commit them.
- Prefer a local Ollama backend if you'd rather no prompts leave your machine.
