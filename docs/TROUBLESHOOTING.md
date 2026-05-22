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

## Community references

- Cursor forum: workspace moves and chat history (search "workspaceStorage" / "composerHeaders")
- Report upstream if a Cursor upgrade breaks metadata keys — scripts target current 3.x SQLite layout
