# Full migration procedure

> **Faster alternative:** use the agent-assisted flow in [RUNBOOK.md](RUNBOOK.md) with `auto-migrate.ps1` (auto-detects hashes/slugs, supports `-DryRun`, includes E2E verification). The steps below are the original manual config-driven procedure.

## Prerequisites

- **Cursor >= 2.1.42** (hook behavior; chat metadata format may change in older builds)
- **Quit Cursor** before any script that touches `%APPDATA%\Cursor\`
- PowerShell 5.1+ (Windows); Python 3.9+ for `fix-chat-metadata.py`
- Enough disk space for a full folder copy

## 1. Prepare config

```powershell
cd path\to\cursor-workspace-migration
Copy-Item migration.config.example.json migration.config.json
```

Fill in:

| Field | How to get it |
|-------|----------------|
| `source_folder` / `destination_folder` | Absolute Windows paths |
| `old_project_slug` / `new_project_slug` | Under `%USERPROFILE%\.cursor\projects\` — slug is derived from path (e.g. `c-Users-YOU-Downloads-MyProject`) |
| `old_workspace_hash` | Run `scripts/find-workspace-hash.ps1` while old folder was last opened |
| `new_workspace_hash` | After step 3: open **destination** once, quit Cursor, run `find-workspace-hash.ps1` again |
| `destination_folder_uri` | `file:///c%3A/Users/...` URL encoding of destination path (see Cursor `workspace.json` in new hash folder) |

## 2. Copy project files + rename projects slug

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\migrate-workspace.ps1
```

This uses `robocopy` and renames `.cursor/projects/<old-slug>` → `<new-slug>` if present.

## 3. Bootstrap destination workspace hash

1. Open Cursor → **File → Open Folder** → destination path.
2. Confirm a new row appears in `find-workspace-hash.ps1` output.
3. **Quit Cursor** again.
4. Update `migration.config.json` with `new_workspace_hash`.

## 4. Restore chat sidebar (workspaceStorage)

```powershell
.\scripts\migrate-chats.ps1
```

Copies `state.vscdb` (+ WAL/shm, images) from old hash directory to new hash directory.

## 5. Fix titles and "New Agent" tabs (global DB)

```powershell
python .\scripts\fix-chat-metadata.py
```

This script:

- Backs up `globalStorage/state.vscdb`
- Remaps `composer.composerHeaders` entries from `old_workspace_hash` → `new_workspace_hash`
- Removes empty ghost headers bound to the new workspace
- Full-copies old `workspaceStorage` tree to new hash (with updated `workspace.json`)
- Patches path strings inside workspace `state.vscdb`

## 6. Verify

1. Open destination folder in Cursor.
2. Chat sidebar should list previous threads with correct titles.
3. Open an old thread — agent transcripts live under `.cursor/projects/<new-slug>/agent-transcripts/`.

## macOS notes

Paths differ:

- `~/.cursor/projects/`
- `~/Library/Application Support/Cursor/User/workspaceStorage/`
- `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`

Scripts are Windows-first; adapt paths manually or port the PowerShell steps to shell.

## Optional: archive source

After a week of verification, delete or move the old source folder. Keep any `*.bak-*` folders until you are confident.
