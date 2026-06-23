#Requires -Version 5.1
<#
.SYNOPSIS
  Auto-detect workspace hashes/slugs and migrate Cursor chat metadata after folder move.
  Run ONLY when Cursor is fully quit (except -DryRun which is read-only).
.PARAMETER Source
  Absolute path to the source project folder.
.PARAMETER Destination
  Absolute path to the destination project folder.
.PARAMETER DryRun
  Read-only preview; does not modify any databases.
.PARAMETER ConfigPath
  Optional migration.config.json (overrides -Source/-Destination if present).
#>
param(
    [string]$Source,
    [string]$Destination,
    [switch]$DryRun,
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot
$PythonScript = Join-Path $ScriptDir "remap-cursor-meta.py"
$CountPy = Join-Path $ScriptDir "count-threads.py"

function Load-Config {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        throw "Missing config: $Path"
    }
    Get-Content $Path -Raw | ConvertFrom-Json
}

if ($ConfigPath -and (Test-Path $ConfigPath)) {
    $cfg = Load-Config $ConfigPath
    if (-not $Source)      { $Source = $cfg.source_folder }
    if (-not $Destination) { $Destination = $cfg.destination_folder }
}

if (-not $Source -or -not $Destination) {
    throw "Provide -Source and -Destination (or -ConfigPath with migration.config.json)."
}

$SourceFolder = (Resolve-Path $Source).Path.TrimEnd('\')
$DestFolder   = (Resolve-Path $Destination -ErrorAction SilentlyContinue).Path
if (-not $DestFolder) {
    throw "Destination folder missing: $Destination`nCopy project files first."
}
$DestFolder = $DestFolder.TrimEnd('\')

function Encode-FolderUri {
    param([string]$Path)
    $normalized = $Path -replace '\\', '/'
    $encoded = [uri]::EscapeDataString($normalized).Replace('%3A', ':')
    return "file:///$encoded"
}

function Normalize-FsPath {
    param([string]$Path)
    if (-not $Path) { return "" }
    try {
        $decoded = [uri]::UnescapeDataString($Path)
        $decoded = $decoded -replace '^file:///', '' -replace '^file:/', ''
        return ($decoded -replace '/', '\').TrimEnd('\')
    } catch {
        return $Path.TrimEnd('\')
    }
}

function Find-WorkspaceHash {
    param([string]$FolderPath)
    $root = Join-Path $env:APPDATA "Cursor\User\workspaceStorage"
    if (-not (Test-Path $root)) { return $null }

    $target = $FolderPath.TrimEnd('\')
    foreach ($dir in Get-ChildItem $root -Directory) {
        $wj = Join-Path $dir.FullName "workspace.json"
        if (-not (Test-Path $wj)) { continue }
        try {
            $folder = (Get-Content $wj -Raw | ConvertFrom-Json).folder
            $decodedFs = Normalize-FsPath $folder
            if ($decodedFs -ieq $target) { return $dir.Name }
        } catch { }
    }
    return $null
}

function Get-ExpectedSlug {
    param([string]$FolderPath)
    $p = $FolderPath.TrimEnd('\')
    if ($p -match '^([A-Za-z]):(.*)$') {
        $drive = $Matches[1].ToLower()
        $rest = $Matches[2]
    } else {
        return $null
    }
    $rest = $rest -replace '\\', '-'
    $rest = $rest -replace '\s+', '-'
    $rest = $rest -replace '[()]', ''
    # Non-ASCII chars (e.g. Polish ł in Własne -> W-asne) become hyphen
    $rest = [regex]::Replace($rest, '[^\x00-\x7F]', '-')
    $rest = $rest -replace '--+', '-'
    $rest = $rest.Trim('-')
    return "$drive-$rest"
}

function Find-ProjectSlug {
    param([string]$FolderPath)
    $projectsRoot = Join-Path $env:USERPROFILE ".cursor\projects"
    $expected = Get-ExpectedSlug $FolderPath

    if ($expected -and (Test-Path (Join-Path $projectsRoot $expected))) {
        return $expected
    }

    # Fallback: scan slugs whose decoded path ends with the folder basename
    $basename = Split-Path $FolderPath -Leaf
    foreach ($dir in Get-ChildItem $projectsRoot -Directory -ErrorAction SilentlyContinue) {
        if ($dir.Name -like "*$basename*") { return $dir.Name }
    }
    return $expected
}

function Copy-ProjectSlug {
    param(
        [string]$OldSlug,
        [string]$NewSlug,
        [switch]$DryRun
    )
    $projectsRoot = Join-Path $env:USERPROFILE ".cursor\projects"
    $oldPath = Join-Path $projectsRoot $OldSlug
    $newPath = Join-Path $projectsRoot $NewSlug

    if (-not (Test-Path $oldPath)) {
        Write-Host "WARN: old project slug missing: $oldPath" -ForegroundColor Yellow
        return
    }

    if ($DryRun) {
        Write-Host "[dry-run] would copy slug $OldSlug -> $NewSlug"
        $oldTranscripts = Join-Path $oldPath "agent-transcripts"
        if (Test-Path $oldTranscripts) {
            $n = (Get-ChildItem $oldTranscripts -Recurse -File -ErrorAction SilentlyContinue).Count
            Write-Host "[dry-run] agent-transcripts in old slug: $n files"
        }
        return
    }

    if (Test-Path $newPath) {
        $bak = "$newPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Write-Host "Backing up existing new slug -> $bak"
        Rename-Item $newPath $bak
    }

    Write-Host "Copying project slug $OldSlug -> $NewSlug ..."
    Copy-Item -Path $oldPath -Destination $newPath -Recurse -Force
    Write-Host "OK: copied $newPath" -ForegroundColor Green
}

Write-Host "=== Cursor workspace migration (auto) ===" -ForegroundColor Cyan
Write-Host "Source:      $SourceFolder"
Write-Host "Destination: $DestFolder"
if ($DryRun) { Write-Host "MODE: DRY-RUN (read-only)" -ForegroundColor Yellow }

if (-not $DryRun) {
    if (Get-Process Cursor -ErrorAction SilentlyContinue) {
        throw "Quit Cursor before migration (Cursor.exe is running). File -> Exit"
    }
}

$oldWs = Find-WorkspaceHash $SourceFolder
$newWs = Find-WorkspaceHash $DestFolder
$oldSlug = Find-ProjectSlug $SourceFolder
$newSlug = Find-ProjectSlug $DestFolder
$destUri = Encode-FolderUri $DestFolder

Write-Host ""
Write-Host "Detected:" -ForegroundColor Cyan
Write-Host "  old workspace hash: $oldWs"
Write-Host "  new workspace hash: $newWs"
Write-Host "  old project slug:   $oldSlug"
Write-Host "  new project slug:   $newSlug"
Write-Host "  dest folder URI:    $destUri"

if (-not $oldWs) {
    throw "Cannot find workspaceStorage hash for source folder. Open source in Cursor once, then quit."
}

if (-not $oldSlug) {
    throw "Cannot determine old project slug."
}

if (-not $newSlug) {
    $newSlug = Get-ExpectedSlug $DestFolder
    Write-Host "  (predicted new slug: $newSlug)"
}

if ((Test-Path $CountPy) -and $oldWs) {
    $out = python $CountPy $oldWs 2>$null
    if ($out -match '^(\d+)\|(\d+)\|(\d+)$') {
        Write-Host "  threads on old workspace: $($Matches[1]) (ghosts: $($Matches[2]), named: $($Matches[3]))"
    }
}

if (-not $newWs) {
    Write-Host ""
    Write-Host "ERROR: new workspace hash not found." -ForegroundColor Red
    Write-Host "Open the destination folder in Cursor ONCE, then quit Cursor, then re-run."
    Write-Host "  Folder: $DestFolder"
    exit 2
}

Write-Host ""
Write-Host "Step 1: Copy project slug (agent transcripts)..." -ForegroundColor Cyan
Copy-ProjectSlug -OldSlug $oldSlug -NewSlug $newSlug -DryRun:$DryRun

Write-Host ""
Write-Host "Step 2: Remap workspaceStorage + composer headers..." -ForegroundColor Cyan
$pyArgs = @(
    $PythonScript,
    "--source", $SourceFolder,
    "--dest", $DestFolder,
    "--old-ws", $oldWs,
    "--new-ws", $newWs,
    "--dest-uri", $destUri
)
if ($DryRun) { $pyArgs += "--dry-run" }

python @pyArgs
if ($LASTEXITCODE -ne 0) { throw "remap-cursor-meta.py failed with exit $LASTEXITCODE" }

Write-Host ""
if ($DryRun) {
    Write-Host "DRY-RUN complete. No changes written." -ForegroundColor Yellow
    Write-Host "When ready: quit Cursor, open dest once, quit again, run without -DryRun."
} else {
    Write-Host "MIGRATION COMPLETE." -ForegroundColor Green
    Write-Host "Open in Cursor: $DestFolder"
    $verifyScript = Join-Path $ScriptDir "verify-migration.ps1"
    Write-Host "Then run: $verifyScript -Source `"$SourceFolder`" -Destination `"$DestFolder`""
}
