# List Cursor workspaceStorage hash <-> folder path (Windows).
#Requires -Version 5.1
$ErrorActionPreference = "Stop"

$root = Join-Path $env:APPDATA "Cursor\User\workspaceStorage"
if (-not (Test-Path $root)) { throw "Not found: $root" }

Write-Host "Hash`tFolder" -ForegroundColor Cyan
Get-ChildItem $root -Directory | ForEach-Object {
    $hash = $_.Name
    $wj = Join-Path $_.FullName "workspace.json"
    $folder = "(no workspace.json)"
    if (Test-Path $wj) {
        try {
            $j = Get-Content $wj -Raw | ConvertFrom-Json
            $folder = $j.folder
        } catch { $folder = "(parse error)" }
    }
    Write-Host "$hash`t$folder"
}
