# Copy workspaceStorage state DB (chat sidebar UI) from old hash to new hash.
# Requires Cursor to be quit. Destination workspace must exist (open folder once first).
#Requires -Version 5.1
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "..\migration.config.json")
)
$ErrorActionPreference = "Stop"

if (-not (Test-Path $ConfigPath)) {
    throw "Missing $ConfigPath — copy migration.config.example.json"
}
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$OldWs = Join-Path $env:APPDATA "Cursor\User\workspaceStorage\$($cfg.old_workspace_hash)"
$NewWs = Join-Path $env:APPDATA "Cursor\User\workspaceStorage\$($cfg.new_workspace_hash)"
$folderJson = (@{
    folder = $cfg.destination_folder_uri
} | ConvertTo-Json -Compress)

if (Get-Process Cursor -ErrorAction SilentlyContinue) {
    throw "Quit Cursor before running this script."
}
if (-not (Test-Path $OldWs)) { throw "Old workspaceStorage not found: $OldWs" }
if (-not (Test-Path $NewWs)) {
    throw "New workspaceStorage not found: $NewWs — open destination folder in Cursor once, then quit."
}

$bak = "$NewWs.bak-chat-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Write-Host "Backup new WS -> $bak"
Copy-Item $NewWs $bak -Recurse

Write-Host "Copying state.vscdb + images from old workspace..."
foreach ($f in @("state.vscdb", "state.vscdb-shm", "state.vscdb-wal", "state.vscdb.backup")) {
    $src = Join-Path $OldWs $f
    if (Test-Path $src) {
        Copy-Item $src (Join-Path $NewWs $f) -Force
        Write-Host "  OK $f"
    }
}
$oldImg = Join-Path $OldWs "images"
$newImg = Join-Path $NewWs "images"
if (Test-Path $oldImg) {
    if (Test-Path $newImg) { Remove-Item $newImg -Recurse -Force }
    Copy-Item $oldImg $newImg -Recurse -Force
    Write-Host "  OK images/"
}

[System.IO.File]::WriteAllText((Join-Path $NewWs "workspace.json"), $folderJson)
Write-Host "OK: workspace.json updated" -ForegroundColor Green
Write-Host "Open Cursor -> destination folder -> chat history should appear in sidebar."
