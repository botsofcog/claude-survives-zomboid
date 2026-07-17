# Publishing to the Steam Workshop

The Workshop item is only the **in-game half**. It does nothing without the companion **bridge**
(the "brain") from this repo, so the listing must say so loudly — this guide's `workshop.txt` and
the template description already do.

## One-time prep

1. Edit `workshop/workshop.txt`:
   - Replace `https://github.com/botsofcog/...` with your actual repo URL.
   - Set `author=` to your name.
   - Leave `id=` blank for a first upload (Steam fills it in and rewrites the file).
2. Add a **preview image**: put a `preview.png` (512×512 recommended) in `workshop/`. See
   `docs/screenshots/README.md` for how to grab one.

## Upload

Project Zomboid has a built-in Workshop uploader:

1. Copy the whole `workshop/` folder into your Zomboid Workshop staging area, renamed to your
   project, e.g. `%USERPROFILE%\Zomboid\Workshop\ClaudeSurvives\` — it must contain
   `workshop.txt` and `Contents/mods/ClaudeSurvivor/...` (this repo's `workshop/` already has that
   layout).
2. Launch Project Zomboid → main menu → **Workshop** → **Create and Update Mods**.
3. Pick your item, confirm the preview + description, agree to the Steam Workshop Legal Agreement,
   and **Upload**.
4. Steam writes the new `id=` back into `workshop.txt`. Keep that file for future updates.

## Updating later

Bump the mod version in `mods/ClaudeSurvivor/mod.info` if you like, re-copy the latest mod into
`workshop/Contents/mods/`, and run the uploader again on the same item (the `id=` links it).

## Set expectations in the listing

Workshop users expect one-click mods. This one isn't — it needs an external app and an AI backend.
Be upfront (the template is), link the GitHub setup guide prominently, and mention the **free**
Ollama path so it doesn't read as "paid only." Honest framing saves you a wave of confused comments.
