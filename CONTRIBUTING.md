# Contributing

This is a young, iterative project and help is very welcome — survival *quality* is the frontier.

## Layout

- `mods/ClaudeSurvivor/media/lua/client/ClaudeSurvivor.lua` — the whole in-game side: perception, the reflex (fight/flee), actions, the HUD. One file, ~640 lines.
- `bridge/pz-bridge.mjs` — the brain loop + `/mind` dashboard.
- `bridge/llm.mjs` — pluggable LLM backends.
- `docs/ARCHITECTURE.md` — read this first; it explains the brain/reflex split.

## Dev loop

1. Edit the Lua and re-run `install.ps1` (or copy `mods/ClaudeSurvivor` into `~/Zomboid/mods/`).
2. In-game, apply a Lua change with **Esc → Quit to Main Menu → Continue** (reloads mod Lua). Launch with `-debug` for the Lua console + `console.txt` logging.
3. Edit the bridge and just restart `node pz-bridge.mjs`.

Guard every game API call in `pcall` — a mod error must never crash the run. The percept's `err`
field surfaces the last failure to the dashboard.

## High-value areas

- **Pathing** — moves are currently blind/directional and clip obstacles. Pathability-aware target selection or waypointing would be a big win.
- **Combat discipline** — spacing, backpedal, shove, weapon-aware engage/disengage.
- **Crafting/healing** — rip clothing → bandages, apply bandages to wounds (routes through crafting/health systems; do it carefully behind `pcall`).
- **Sneaking / stance**, barricading, cooking, water sources.
- **New backends** in `llm.mjs` — follow the existing pattern (a function that takes a prompt, returns text).

## Style

Match the surrounding code. Keep it readable and dependency-free (the bridge uses only Node
built-ins + `fetch`). Prefer clarity over cleverness.

## Compatibility

Target **Build 42** (pin a point release; the API moves between unstable builds). Note the build
you tested against in your PR.
