# Cursor workspace migration (files + chat history + titles)

Move a Cursor project folder to a new path **without losing Agent/Composer chats, thread titles, or draft state**.

Tested on **Cursor 3.x** (Windows). Requires **Cursor >= 2.1.42** so hook responses are honored (see [Cursor hooks docs](https://cursor.com/docs/hooks)).

## The problem

Cursor stores project-related data in **three separate places**:

| Layer | Location | What you lose if you only copy files |
|-------|----------|--------------------------------------|
| 1. Project files | Your folder on disk | N/A (you copy this) |
| 2. Agent transcripts | `%USERPROFILE%\.cursor\projects\<slug>\` | Partial — rename slug helps |
| 3. Chat sidebar (titles, sections) | `%APPDATA%\Cursor\User\workspaceStorage\<hash>\` | **Empty sidebar** in new folder |
| 4. Thread names & workspace binding | Global `%APPDATA%\Cursor\User\globalStorage\state.vscdb` → `composer.composerHeaders` | **"New Agent"** tabs, wrong titles |

Copying files alone is **not enough**. Renaming only `.cursor/projects/...` is **not enough**.

## Agent-assisted quick path (recommended)

For automated hash/slug detection, dry-run, and E2E verification — see **[docs/RUNBOOK.md](docs/RUNBOOK.md)**.

```powershell
# Phase A (agent): copy files, then:
.\scripts\parity-check.ps1 -Source "C:\old\path" -Dest "C:\new\path" -ExcludeVolatile
.\scripts\auto-migrate.ps1 -Source "C:\old\path" -Destination "C:\new\path" -DryRun

# Phase B (you, Cursor quit): open dest once, quit, then:
.\scripts\auto-migrate.ps1 -Source "C:\old\path" -Destination "C:\new\path"

# Phase C (agent):
.\scripts\verify-migration.ps1 -Source "C:\old\path" -Destination "C:\new\path"
```

Cursor assets in this repo: `.cursor/skills/cursor-workspace-migration/` (skill) and `.cursor/agents/workspace-migrator.md` (subagent).

## Quick start — manual config (Windows)

1. **Quit Cursor** completely (File → Exit).
2. Copy `migration.config.example.json` → `migration.config.json` and fill in paths + workspace hashes (use `scripts/find-workspace-hash.ps1`).
3. Run `scripts/migrate-workspace.ps1`
4. Open the **destination** folder once in Cursor (creates workspace hash if missing), then **quit Cursor again**.
5. Run `scripts/migrate-chats.ps1` (copies `workspaceStorage` DB).
6. Run `scripts/fix-chat-metadata.py` (remaps titles + fixes "New Agent" ghosts).
7. Re-open destination folder. Re-index semantic search if you use [claude-context](https://github.com/zilliztech/claude-context) (indexes are **per absolute path** — see [docs/INDEXING.md](docs/INDEXING.md)).

## Documentation

- [docs/RUNBOOK.md](docs/RUNBOOK.md) — **agent-assisted migration** (recommended, with case study)
- [docs/MIGRATION.md](docs/MIGRATION.md) — full manual step-by-step procedure
- [docs/INDEXING.md](docs/INDEXING.md) — claude-context / CodeGraph after path change
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — empty chats, wrong titles, version issues

## Scripts

| Script | Purpose |
|--------|---------|
| `auto-migrate.ps1` | **Auto-detect** hashes/slugs, copy slug + remap metadata (`-DryRun` supported) |
| `verify-migration.ps1` | **E2E verification** with confidence score after migration |
| `parity-check.ps1` | sha256 file parity (`-ExcludeVolatile` for planning artifacts) |
| `remap-cursor-meta.py` | Remap `composer.composerHeaders` (called by auto-migrate) |
| `count-threads.py` | Count threads/ghosts per workspace hash |
| `find-workspace-hash.ps1` | List `workspaceStorage` hash ↔ folder path |
| `migrate-workspace.ps1` | Copy project files + rename `.cursor/projects` slug (manual flow) |
| `migrate-chats.ps1` | Copy `workspaceStorage` state DB (manual flow) |
| `fix-chat-metadata.py` | Remap headers via `migration.config.json` (manual flow) |

## Security

- **Do not commit** `migration.config.json` (local paths only).
- This repo contains **no API keys**, no `mcp.json`, no personal tokens.

## License

MIT — see [LICENSE](LICENSE).
