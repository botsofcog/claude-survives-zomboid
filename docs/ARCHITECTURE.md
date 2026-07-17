# Architecture

## The core problem

Project Zomboid is real-time. A zombie kills you in the second it takes to reach you. An LLM
takes *several* seconds to answer. If you naively ask an LLM "what do I do?" every few seconds and
nothing else, your survivor gets eaten mid-thought, every time.

So control is split into two layers running at two very different speeds.

## Two layers

```
 ┌──────────────────────────────────────────────────────────────┐
 │  BRAIN  (Claude / GPT / Gemini / Ollama, via the Node bridge) │
 │  every ~5s · slow · strategic                                 │
 │  "clear that house to the east, grab a weapon, then hole up"  │
 └───────────────┬──────────────────────────────────────────────┘
                 │ intent (MOVE/LOOT/EAT/EQUIP/CLOSEDOOR/WAIT…)
                 ▼
 ┌──────────────────────────────────────────────────────────────┐
 │  REFLEX  (Lua, inside the game)                               │
 │  every few ticks · instant · tactical survival               │
 │  fight a lone attacker · flee a swarm · dodge · close doors   │
 └──────────────────────────────────────────────────────────────┘
```

- **The brain** sets *intent*: where to go and why. It never micromanages a fight.
- **The reflex** keeps the body alive between thoughts. It's deterministic Lua that runs on the
  game's own clock, so it reacts in the same tick a threat appears — no round-trip.

This is why the survivor can fight and flee competently despite the brain being "slow." The brain
decides *strategy*; the reflex owns *reaction*.

## The reflex, specifically

- **Flee** — a repulsion vector summed away from every nearby zombie (closer = stronger), so it
  escapes along the safest heading instead of blindly away from one and into two others.
- **Fight** — when armed, not swarmed, and healthy enough, it closes on a lone zombie and swings
  (`DoAttack`). Only flees when it would actually lose: unarmed, outnumbered, or badly hurt.
- **Momentum** — keeps the body drifting along its heading between decisions so it never freezes.
- **Awareness** — glances toward nearby threats; scans the compass while deliberately observing.
- **Doors** — closes doors behind it to buy time.

## The bridge

`bridge/pz-bridge.mjs`:
1. Watches `~/Zomboid/Lua/claude_percept.json` (senses the mod writes ~1/s).
2. On an adaptive cadence, builds a compact prompt (persona + the AI's own memory + last few
   decisions + current senses) and asks the LLM (`bridge/llm.mjs`, any backend).
3. Parses the JSON decision and writes `~/Zomboid/Lua/claude_intent.txt`.
4. Serves the `/mind` dashboard and a "voice from beyond" text channel.

The AI rewrites its own **memory** scratchpad each turn — that's the real continuity, not the log.

## Why files, not sockets

Build 42 mod Lua has no general socket API (and the HTTP-GET global present in some builds isn't
reliable), but it has sandboxed file I/O into `~/Zomboid/Lua/`. So the two halves rendezvous
through two small text files there. It's simple, robust, and needs no ports or permissions.

## The transparency layer

Everything the AI perceives and decides is surfaced so you can watch it think:
- **In-game HUD** — action, live inner monologue, vitals, zombie proximity, inventory.
- **Speech bubbles** — it says its decisions aloud, first person.
- **Visible body language** — turns to scan, glances at threats.
- **Web dashboard** — the same, in a browser, plus a channel to text it.
