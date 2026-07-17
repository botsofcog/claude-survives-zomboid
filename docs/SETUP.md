# Setup & troubleshooting

Claude Survives has two halves that talk through your Zomboid folder:

- **The mod** (`mods/ClaudeSurvivor`) — runs *inside* Project Zomboid, reads the game, drives the body.
- **The bridge** (`bridge/pz-bridge.mjs`) — a Node script that reads the mod's perception, asks Claude what to do, and writes back the decision. It also serves the live dashboard.

Both must be running. The mod alone does nothing.

## Requirements

- **Project Zomboid — Build 42** (Steam → Properties → Betas → `unstable`, until B42 is stable). Verified on 42.19.
- **Node.js 18+** — <https://nodejs.org/>
- **A Claude connection**, either:
  - the [`claude` CLI](https://docs.claude.com/en/docs/claude-code/overview) on your PATH (uses your Claude subscription), or
  - an `ANTHROPIC_API_KEY` (see [bridge/README.md](../bridge/README.md) for the tiny change to use the API directly).

## Install the mod

**Option A — helper script (Windows):**
```powershell
pwsh ./install.ps1
```
It copies the mod into `%USERPROFILE%\Zomboid\mods\ClaudeSurvivor`.

**Option B — manual:** copy the `mods/ClaudeSurvivor` folder into:
- Windows: `%USERPROFILE%\Zomboid\mods\`
- Linux: `~/Zomboid/mods/`
- macOS: `~/Zomboid/mods/`

## Run the brain

```bash
cd bridge
node pz-bridge.mjs
```
You should see:
```
pz-bridge up on http://localhost:8799/mind
```
Leave it running.

## Play

1. Launch Project Zomboid → **Mods** → enable **Claude Survivor** → back out.
2. **Solo → New Game → Sandbox.** Any spawn works; Muldraugh/Riverside are classic.
3. Once in-world, **stop touching the controls.** Within a few seconds the AI takes over.
4. Watch the **in-game HUD** (bottom-left, toggle **H**) and **<http://localhost:8799/mind>**.

## Controls

| Key | Action |
|-----|--------|
| **H** | Toggle the in-game HUD |
| **G** | Toggle AI auto game-speed |
| move keys | Take manual control; AI resumes ~10s after you stop moving |

## Troubleshooting

**Mod isn't listed in-game.** B42 needs a `mod.info` at the mod root *and* inside the `42/` folder — this repo ships both. Confirm `%USERPROFILE%\Zomboid\mods\ClaudeSurvivor\mod.info` exists, and re-open the Mods screen (it re-scans on entry).

**Dashboard says "no fresh percept."** The game isn't running, the mod isn't enabled, or you're not in-world yet. Perception only flows once your survivor has spawned.

**He stands still / does nothing.** Check the brain terminal for errors. If `claude` isn't found, install the CLI or set `ANTHROPIC_API_KEY`. The dashboard's `brain:` line tells you what's happening.

**A code change won't take effect.** The mod's Lua is loaded when the world loads. To apply an edit: **Esc → Quit to Main Menu → Continue** (reloads the save and all mod Lua).

**It's slow / long pauses.** The brain uses the fast **Haiku** model by default (`PZ_MODEL=haiku`). Each decision is a few seconds; the local reflex handles anything faster. You can set `PZ_MODEL=sonnet` for smarter (slower) play.

**He keeps dying.** He's supposed to — it's a zombie apocalypse and survival quality is a work in progress. See the roadmap in the main README.
