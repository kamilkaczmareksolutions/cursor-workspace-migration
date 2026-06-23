#Requires -Version 5.1
<#
.SYNOPSIS
  Full E2E verification after workspace migration. Reports confidence score.
.PARAMETER Source
  Absolute path to the source project folder (kept as backup).
.PARAMETER Destination
  Absolute path to the destination project folder.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Source,
    [Parameter(Mandatory = $true)]
    [string]$Destination
)

$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot
$parityScript = Join-Path $ScriptDir "parity-check.ps1"
$countPy = Join-Path $ScriptDir "count-threads.py"

$Source = (Resolve-Path $Source).Path.TrimEnd('\')
$Dest = (Resolve-Path $Destination).Path.TrimEnd('\')

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
    $target = $FolderPath.TrimEnd('\')
    foreach ($dir in Get-ChildItem $root -Directory -ErrorAction SilentlyContinue) {
        $wj = Join-Path $dir.FullName "workspace.json"
        if (-not (Test-Path $wj)) { continue }
        try {
            $folder = (Get-Content $wj -Raw | ConvertFrom-Json).folder
            $decodedFs = Normalize-FsPath $folder
            if ($decodedFs -ieq $target) {
                return @{ Hash = $dir.Name; Uri = $folder }
            }
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
    } else { return $null }
    $rest = $rest -replace '\\', '-'
    $rest = $rest -replace '\s+', '-'
    $rest = $rest -replace '[()]', ''
    $rest = [regex]::Replace($rest, '[^\x00-\x7F]', '-')
    $rest = $rest -replace '--+', '-'
    $rest = $rest.Trim('-')
    return "$drive-$rest"
}

function Count-Threads {
    param([string]$WsHash)
    if (-not (Test-Path $countPy)) { return @{ Count = -1; Ghosts = -1; Named = -1 } }
    $out = python $countPy $WsHash 2>$null
    if ($out -match '^(\d+)\|(\d+)\|(\d+)$') {
        return @{
            Count = [int]$Matches[1]
            Ghosts = [int]$Matches[2]
            Named = [int]$Matches[3]
        }
    }
    return @{ Count = -1; Ghosts = -1; Named = -1 }
}

$results = @()
function Test-Check {
    param(
        [string]$Name,
        [bool]$Ok,
        [string]$Detail = "",
        [ValidateSet("hard", "soft")]
        [string]$Severity = "hard"
    )
    $status = if ($Ok) { "PASS" } else { if ($Severity -eq "soft") { "INFO" } else { "FAIL" } }
    $color = if ($Ok) { "Green" } elseif ($Severity -eq "soft") { "Yellow" } else { "Red" }
    Write-Host "[$status] $Name" -ForegroundColor $color
    if ($Detail) { Write-Host "       $Detail" }
    $script:results += [pscustomobject]@{
        Test = $Name
        Pass = $Ok
        Severity = $Severity
        Detail = $Detail
    }
}

Write-Host "=== E2E Migration Verification ===" -ForegroundColor Cyan
Write-Host "Source: $Source"
Write-Host "Dest:   $Dest"
Write-Host ""

# Test 1: File parity (exclude volatile planning artifacts)
Write-Host "--- Test 1: File parity ---" -ForegroundColor Cyan
& $parityScript -Source $Source -Dest $Dest -ExcludeVolatile
$parityOk = ($LASTEXITCODE -eq 0)
Test-Check "File parity (sha256+size, volatile excluded)" $parityOk

# Test 2: workspaceStorage
Write-Host ""
Write-Host "--- Test 2: workspaceStorage ---" -ForegroundColor Cyan
$destWs = Find-WorkspaceHash $Dest
if ($destWs) {
    $wsDb = Join-Path $env:APPDATA "Cursor\User\workspaceStorage\$($destWs.Hash)\state.vscdb"
    Test-Check "workspaceStorage hash exists" $true "hash=$($destWs.Hash)"
    Test-Check "workspace state.vscdb exists" (Test-Path $wsDb) $wsDb
    $destBasename = Split-Path $Dest -Leaf
    $uriOk = (Normalize-FsPath $destWs.Uri -ieq $Dest) -or ($destWs.Uri -like "*$destBasename*")
    Test-Check "workspace.json points to dest" $uriOk $destWs.Uri
} else {
    Test-Check "workspaceStorage hash exists" $false "not found for $Dest"
}

# Test 3: composer headers (MOVE semantics + benign ghost)
Write-Host ""
Write-Host "--- Test 3: composer.composerHeaders ---" -ForegroundColor Cyan
$oldWs = Find-WorkspaceHash $Source
$oldHash = if ($oldWs) { $oldWs.Hash } else { "" }
$newHash = if ($destWs) { $destWs.Hash } else { "" }

if ($newHash) {
    $newThreads = Count-Threads $newHash
    if ($oldHash) {
        $oldThreads = Count-Threads $oldHash
    } else {
        $oldThreads = @{ Count = 0; Ghosts = 0; Named = 0 }
    }

    Test-Check "named threads on new workspace > 0" ($newThreads.Named -gt 0) "named=$($newThreads.Named)"
    Test-Check "threads migrated (new named >= old named)" ($newThreads.Named -ge $oldThreads.Named) "old_named=$($oldThreads.Named) new_named=$($newThreads.Named)"

    # MOVE proof: old workspace should have 0 named threads after remap
    $moveOk = ($oldThreads.Named -eq 0)
    Test-Check "MOVE proof: old workspace has 0 named threads" $moveOk "old_named=$($oldThreads.Named)"

    # Benign ghost: single unnamed tab after reopen is informational, not a failure
    $ghostBenign = ($newThreads.Ghosts -le 1)
    if ($newThreads.Ghosts -eq 0) {
        Test-Check "no ghost threads on new workspace" $true "ghosts=0"
    } elseif ($newThreads.Ghosts -eq 1) {
        Test-Check "ghost threads on new workspace (benign if 1)" $true "ghosts=1 (fresh New Chat tab — benign)" -Severity soft
    } else {
        Test-Check "no ghost threads on new workspace" $false "ghosts=$($newThreads.Ghosts)"
    }
} else {
    Test-Check "composer headers on new workspace" $false "no new hash"
}

# Test 4: agent transcripts
Write-Host ""
Write-Host "--- Test 4: agent transcripts ---" -ForegroundColor Cyan
$oldSlug = Get-ExpectedSlug $Source
$newSlug = Get-ExpectedSlug $Dest
$projectsRoot = Join-Path $env:USERPROFILE ".cursor\projects"
$oldTranscriptDir = Join-Path $projectsRoot "$oldSlug\agent-transcripts"
$newTranscriptDir = Join-Path $projectsRoot "$newSlug\agent-transcripts"

if (-not (Test-Path $newTranscriptDir)) {
    $basename = Split-Path $Dest -Leaf
    Get-ChildItem $projectsRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*$basename*" } |
        ForEach-Object {
            $alt = Join-Path $_.FullName "agent-transcripts"
            if (Test-Path $alt) {
                $script:newTranscriptDir = $alt
                $script:newSlug = $_.Name
            }
        }
}

$oldN = if (Test-Path $oldTranscriptDir) {
    (Get-ChildItem $oldTranscriptDir -Recurse -File).Count
} else { 0 }
$newN = if (Test-Path $newTranscriptDir) {
    (Get-ChildItem $newTranscriptDir -Recurse -File).Count
} else { 0 }
$transcriptOk = ($newN -ge $oldN) -and ($newN -gt 0)
Test-Check "new slug agent-transcripts exist" (Test-Path $newTranscriptDir) $newTranscriptDir
Test-Check "transcript count new >= old" $transcriptOk "old=$oldN new=$newN slug=$newSlug"

# Test 5: top-level file presence (generic, no hardcoded filenames)
Write-Host ""
Write-Host "--- Test 5: top-level structure ---" -ForegroundColor Cyan
$srcTop = Get-ChildItem $Source -Force | Select-Object -ExpandProperty Name
$dstTop = Get-ChildItem $Dest -Force | Select-Object -ExpandProperty Name
$missingTop = @()
foreach ($item in $srcTop) {
    if ($item -notin $dstTop) { $missingTop += $item }
}
Test-Check "all source top-level items present in dest" ($missingTop.Count -eq 0) $(if ($missingTop.Count) { "missing: $($missingTop -join ', ')" } else { "count=$($srcTop.Count)" })

# Summary
Write-Host ""
Write-Host "=== SUMMARY ===" -ForegroundColor Cyan
$hardResults = $results | Where-Object { $_.Severity -eq "hard" }
$passed = ($hardResults | Where-Object { $_.Pass }).Count
$total = $hardResults.Count
$allPass = ($hardResults | Where-Object { -not $_.Pass }).Count -eq 0

Write-Host "Passed (hard checks): $passed / $total"
$softInfo = $results | Where-Object { $_.Severity -eq "soft" -and -not $_.Pass }
if ($softInfo) {
    Write-Host "Informational:" -ForegroundColor Yellow
    $softInfo | ForEach-Object { Write-Host "  - $($_.Test): $($_.Detail)" -ForegroundColor Yellow }
}

if ($allPass) {
    Write-Host "CONFIDENCE: 100% - all hard checks PASS" -ForegroundColor Green
    exit 0
} else {
    $failed = $hardResults | Where-Object { -not $_.Pass }
    Write-Host "CONFIDENCE: incomplete - $($failed.Count) hard check(s) FAIL" -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "  - $($_.Test): $($_.Detail)" -ForegroundColor Red }
    exit 1
}
