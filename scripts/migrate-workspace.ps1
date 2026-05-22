# Copy project folder + rename ~/.cursor/projects slug (best-effort).
# Run ONLY when Cursor is fully quit.
#Requires -Version 5.1
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "..\migration.config.json"),
    [string]$Source,
    [string]$Destination,
    [string]$OldProjectSlug,
    [string]$NewProjectSlug
)
$ErrorActionPreference = "Stop"

function Get-Config {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        throw "Missing config: $Path`nCopy migration.config.example.json -> migration.config.json"
    }
    Get-Content $Path -Raw | ConvertFrom-Json
}

$cfg = Get-Config $ConfigPath
$Src = if ($Source) { $Source } else { $cfg.source_folder }
$Dst = if ($Destination) { $Destination } else { $cfg.destination_folder }
$OldProj = if ($OldProjectSlug) {
    Join-Path $env:USERPROFILE ".cursor\projects\$OldProjectSlug"
} else {
    Join-Path $env:USERPROFILE ".cursor\projects\$($cfg.old_project_slug)"
}
$NewProj = if ($NewProjectSlug) {
    Join-Path $env:USERPROFILE ".cursor\projects\$NewProjectSlug"
} else {
    Join-Path $env:USERPROFILE ".cursor\projects\$($cfg.new_project_slug)"
}

Write-Host "=== Cursor workspace migrate ===" -ForegroundColor Cyan
Write-Host "Source:      $Src"
Write-Host "Destination: $Dst"

if (-not (Test-Path $Src)) { throw "Source not found: $Src" }
if (Get-Process Cursor -ErrorAction SilentlyContinue) {
    throw "Quit Cursor before migration (Cursor.exe is running)."
}

New-Item -ItemType Directory -Force -Path $Dst | Out-Null
$robolog = Join-Path $env:TEMP "cursor-migrate-robocopy.log"
robocopy $Src $Dst /E /XD node_modules .git /XF *.log `
    /NFL /NDL /NP /R:2 /W:5 /LOG+:$robolog
if ($LASTEXITCODE -ge 8) { throw "robocopy failed, code $LASTEXITCODE, log: $robolog" }

if (Test-Path $OldProj) {
    if (Test-Path $NewProj) {
        $bak = "$NewProj.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Write-Host "Destination project folder exists -> backup: $bak"
        Rename-Item $NewProj $bak
    }
    Rename-Item $OldProj $NewProj
    Write-Host "OK: renamed Cursor project metadata -> $NewProj" -ForegroundColor Green
} else {
    Write-Host "WARN: missing $OldProj — run migrate-chats.ps1 after first open of destination." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Next steps ===" -ForegroundColor Cyan
Write-Host "1. Open in Cursor: $Dst (once), then quit Cursor."
Write-Host "2. Run scripts/find-workspace-hash.ps1 if you need new_workspace_hash."
Write-Host "3. Run scripts/migrate-chats.ps1"
Write-Host "4. Run scripts/fix-chat-metadata.py"
Write-Host "5. Re-index semantic search (see docs/INDEXING.md)"
Write-Host "Robocopy log: $robolog"
