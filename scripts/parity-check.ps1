#Requires -Version 5.1
<#
.SYNOPSIS
  E2E file parity: sha256 + size for every file in source vs destination.
.PARAMETER ExcludeVolatile
  Skip live planning artifacts (.cursor/plans/, *.plan.md) that change during agent sessions.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Source,
    [Parameter(Mandatory = $true)]
    [string]$Dest,
    [switch]$ExcludeVolatile,
    [string[]]$Exclude = @()
)

$ErrorActionPreference = "Stop"

$DefaultVolatilePatterns = @(
    '\.cursor[\\/]plans[\\/]',
    '\.plan\.md$'
)

function Test-ExcludedPath {
    param([string]$RelativePath)
    $normalized = $RelativePath -replace '/', '\'
    foreach ($pat in $script:AllExcludePatterns) {
        if ($normalized -match $pat) { return $true }
    }
    return $false
}

function Get-FileManifest {
    param([string]$Root)
    $manifest = @{}
    Get-ChildItem -Path $Root -Recurse -File -Force | ForEach-Object {
        $rel = $_.FullName.Substring($Root.Length).TrimStart('\')
        if (Test-ExcludedPath $rel) { return }
        $hash = (Get-FileHash -Path $_.FullName -Algorithm SHA256).Hash
        $manifest[$rel] = @{
            Size = $_.Length
            Hash = $hash
        }
    }
    return $manifest
}

$AllExcludePatterns = @()
if ($ExcludeVolatile) { $AllExcludePatterns += $DefaultVolatilePatterns }
$AllExcludePatterns += $Exclude

Write-Host "=== E2E Parity Test ===" -ForegroundColor Cyan
Write-Host "Source: $Source"
Write-Host "Dest:   $Dest"
if ($ExcludeVolatile) {
    Write-Host "ExcludeVolatile: ON (.cursor/plans/, *.plan.md)" -ForegroundColor Yellow
}

if (-not (Test-Path $Source)) { throw "Source missing: $Source" }
if (-not (Test-Path $Dest))   { throw "Dest missing: $Dest" }

Write-Host "Building manifests (sha256)..."
$srcManifest = Get-FileManifest $Source
$dstManifest = Get-FileManifest $Dest

$srcCount = $srcManifest.Count
$dstCount = $dstManifest.Count
Write-Host "Source files: $srcCount"
Write-Host "Dest files:   $dstCount"

$missingInDest = @()
$extraInDest = @()
$mismatch = @()

foreach ($key in $srcManifest.Keys) {
    if (-not $dstManifest.ContainsKey($key)) {
        $missingInDest += $key
    } elseif ($srcManifest[$key].Hash -ne $dstManifest[$key].Hash) {
        $mismatch += "$key (hash)"
    } elseif ($srcManifest[$key].Size -ne $dstManifest[$key].Size) {
        $mismatch += "$key (size)"
    }
}

foreach ($key in $dstManifest.Keys) {
    if (-not $srcManifest.ContainsKey($key)) {
        $extraInDest += $key
    }
}

$pass = ($missingInDest.Count -eq 0) -and ($extraInDest.Count -eq 0) -and ($mismatch.Count -eq 0) -and ($srcCount -eq $dstCount)

Write-Host ""
if ($missingInDest.Count -gt 0) {
    Write-Host "MISSING in dest ($($missingInDest.Count)):" -ForegroundColor Red
    $missingInDest | Select-Object -First 20 | ForEach-Object { Write-Host "  $_" }
}
if ($extraInDest.Count -gt 0) {
    Write-Host "EXTRA in dest ($($extraInDest.Count)):" -ForegroundColor Red
    $extraInDest | Select-Object -First 20 | ForEach-Object { Write-Host "  $_" }
}
if ($mismatch.Count -gt 0) {
    Write-Host "MISMATCH ($($mismatch.Count)):" -ForegroundColor Red
    $mismatch | Select-Object -First 20 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ""
if ($pass) {
    Write-Host "PASS: $srcCount files, sha256+size match 100%" -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAIL: parity check failed" -ForegroundColor Red
    exit 1
}
