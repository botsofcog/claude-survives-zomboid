<!-- Thanks for contributing to Claude Survives! -->

## What this changes

<!-- One or two sentences. Link any issue it closes: "Closes #12". -->

## Which layer

- [ ] The mod (in-game Lua — perception / reflex / actions / HUD)
- [ ] The bridge (Node — brain loop / LLM backends / dashboard)
- [ ] Docs / packaging / CI

## Testing

- **Project Zomboid build tested:** <!-- e.g. 42.19.0 -->
- **LLM backend tested:** <!-- e.g. Ollama llama3.1 -->
- How I verified it in-game:

## Checklist

- [ ] Game API calls are wrapped in `pcall` (a mod error must never crash the run)
- [ ] `node --check` passes on any changed bridge files
- [ ] I updated docs / `CHANGELOG.md` if behavior changed
