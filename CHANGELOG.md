# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] — 2026-07-16

Initial public release. An LLM plays a Project Zomboid (Build 42) survivor end to end:
perception → decision → action, with a fast in-game reflex layer and full on-screen transparency.

### Added
- **The mod** (`mods/ClaudeSurvivor`, Lua) — the in-game body:
  - Perception feed (vitals, zombies, buildings, inventory, time) written for the brain.
  - Reflex survival layer: repulsion-vector flee, local melee against a lone attacker, fight-or-flee decision.
  - Actions: `MOVE`, `LOOT` (announces the haul), `EAT`, `DRINK`, `EQUIP`, `CLOSEDOOR`, `CONCEAL` (doors + curtains), `BREAKIN` (smash + climb window), `STOP`, `WAIT`.
  - Momentum, threat-glancing, look-around scanning, sneak/crouch, night auto-lights.
  - Building-direction sense so it heads for loot instead of wandering into forest.
  - Human override (take the keyboard; AI auto-resumes ~10s after you stop) and a sparing panic-pause.
  - Auto game-speed (fast-forward safe travel, normal near danger).
  - In-game HUD (bottom-left, toggle **H**): action, live thought, vitals, threats, inventory.
- **The bridge** (`bridge/pz-bridge.mjs` + `llm.mjs`, Node) — the brain:
  - Pluggable, auto-detected LLM backend: **Ollama** (free/local), **Anthropic**, **OpenAI** (+ OpenAI-compatible), **Google Gemini**, **Claude CLI**.
  - Adaptive decision cadence, persistent self-authored memory, and a live `/mind` web dashboard with a "voice from beyond" text channel.
- **Steam Workshop** upload package (`workshop/`) with an honest description.
- **Docs**: setup, architecture, Steam publishing, contributing; a standalone landing page (`docs/index.html`).

### Known limitations
- Movement is directional and can clip obstacles (pathability-aware targeting is on the roadmap).
- Combat is functional but coarse; deeper discipline and selectable styles are planned.
- Crafting/healing (bandages) and line-of-sight cover are not yet implemented.

[1.0.0]: https://github.com/botsofcog/claude-survives-zomboid/releases/tag/v1.0.0
