# Troubleshooting

## Empty chat list after moving files

**Cause:** Only project files (and maybe `.cursor/projects/`) were moved; the UI reads `%APPDATA%\Cursor\User\workspaceStorage\<hash>\state.vscdb`.

**Fix:** Run `migrate-chats.ps1` then `fix-chat-metadata.py` with correct hashes in `migration.config.json`.

## Threads show "New Agent" or wrong titles

**Cause:** `composer.composerHeaders` in **global** `globalStorage/state.vscdb` still points `workspaceIdentifier.id` to the old hash.

**Fix:** `fix-chat-metadata.py` (remaps headers + removes empty ghosts).

## Transcripts exist but sidebar is empty

Transcripts: `%USERPROFILE%\.cursor\projects\<slug>\agent-transcripts\`  
Sidebar: `workspaceStorage/<hash>/state.vscdb`

Both layers must be aligned. Renaming the projects slug alone is insufficient.

## find-workspace-hash shows wrong folder

Open the intended folder in Cursor once, quit, re-run the script. Use the hash whose `workspace.json` `folder` URI matches your destination.

## Cursor hooks or scripts behave oddly

Ensure **Cursor >= 2.1.42**. Older builds may ignore hook JSON responses ([Cursor hooks documentation](https://cursor.com/docs/hooks)).

## Emergency rollback

1. Restore `globalStorage/state.vscdb` from `state.vscdb.bak-meta-*` created by `fix-chat-metadata.py`.
2. Restore `workspaceStorage/<new-hash>` from `*.bak-chat-*` or `*.bak-meta-*`.
3. Re-open the **old** source folder temporarily — UI history reappears for that hash.

## Parity check fails on `.cursor/plans/*.plan.md` only

**Symptom:** `parity-check.ps1` or `verify-migration.ps1` reports a single hash mismatch on a file under `.cursor/plans/`.

**Cause:** Agent planning sessions edit plan files in the source workspace while migration is in progress. This is a live artifact, not lost project data.

**Fix:** Use `-ExcludeVolatile` (enabled by default in `verify-migration.ps1`). Re-run parity — all other files should match.

## Ghost thread count = 1 after reopening destination

**Symptom:** `verify-migration.ps1` reports `ghosts=1` on the new workspace.

**Cause:** Cursor creates a fresh unnamed "New Chat" tab when you open the destination folder. This is normal post-open behavior.

**Verdict:** Benign (soft check). Confirm all **named** threads have correct titles and transcript count matches.

## Slug mismatch for paths with non-ASCII characters

**Symptom:** `auto-migrate.ps1` cannot find the expected project slug for a destination path containing characters like `ł`, `ą`, `ę`.

**Cause:** Cursor converts non-ASCII characters to hyphens in slug names (e.g. `Własne` → `W-asne`).

**Fix:** Check actual slug under `%USERPROFILE%\.cursor\projects\` and compare with `find-workspace-hash.ps1` output. The auto-migrate script scans by folder basename as fallback.

## Community references

- Cursor forum: workspace moves and chat history (search "workspaceStorage" / "composerHeaders")
- Report upstream if a Cursor upgrade breaks metadata keys — scripts target current 3.x SQLite layout
