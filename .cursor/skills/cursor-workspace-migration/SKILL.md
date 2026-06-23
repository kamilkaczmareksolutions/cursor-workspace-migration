---
name: cursor-workspace-migration
description: Moves a Cursor workspace folder to a new path preserving Agent/Composer chats, thread titles, and agent transcripts. Use when relocating a project folder, renaming workspace path, or when the user asks about Cursor chat history migration, workspaceStorage, composer headers, or workspace move on Windows.
---

# Cursor workspace migration

## When to use

- User wants to move/rename a Cursor project folder
- Chats would be lost with a simple file copy
- User mentions `workspaceStorage`, `composer.composerHeaders`, agent transcripts, or workspace slug

## Three-phase process

**Phase A (agent, Cursor open):** copy files → `parity-check.ps1 -ExcludeVolatile` → `auto-migrate.ps1 -DryRun`

**Phase B (human, Cursor closed):** quit Cursor → open destination once → quit → `auto-migrate.ps1` → reopen destination

**Phase C (agent):** `verify-migration.ps1` → report confidence score

Full procedure: [docs/RUNBOOK.md](../../docs/RUNBOOK.md)

## Scripts (repo `scripts/`)

| Script | When |
|--------|------|
| `parity-check.ps1 -Source -Dest [-ExcludeVolatile]` | After file copy (Phase A) |
| `auto-migrate.ps1 -Source -Destination [-DryRun]` | Dry-run in A; real run in B (Cursor quit) |
| `verify-migration.ps1 -Source -Destination` | After reopening dest (Phase C) |
| `find-workspace-hash.ps1` | Debug hash ↔ path mapping |

Legacy config-driven flow still works: `migrate-workspace.ps1` → `migrate-chats.ps1` → `fix-chat-metadata.py`.

## Critical rules

1. **Never** remap `state.vscdb` while Cursor is running
2. Destination must be opened in Cursor **once** before `auto-migrate.ps1` (creates new workspace hash)
3. Use **copy** not rename for source folder (keep backup)
4. Robocopy exit codes 0–7 = success (1 = files copied)

## Known false positives (do not fail migration)

1. **Parity mismatch on `.cursor/plans/*.plan.md`** — live planning artifact; use `-ExcludeVolatile`
2. **Ghost count = 1 after reopen** — fresh "New Chat" tab; soft/benign if all named threads present

## Confidence 100%

`verify-migration.ps1` must report: `CONFIDENCE: 100% - all hard checks PASS`

Key hard checks: parity (volatile excluded), new workspaceStorage hash, named threads > 0, MOVE proof (old ws named = 0), transcripts new >= old.

## Post-migration

Re-index semantic tools (claude-context, CodeGraph) — indexes are per absolute path. See [docs/INDEXING.md](../../docs/INDEXING.md).
