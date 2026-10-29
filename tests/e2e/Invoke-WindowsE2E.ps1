#Requires -Version 5.1
<#
.SYNOPSIS
  End-to-end test of auto-migrate.ps1 + verify-migration.ps1 on real Windows paths
  against fake Cursor data. CI only: wipes and rebuilds C:\cwm-test.
  The caller must point APPDATA and USERPROFILE at C:\cwm-test\fake\... (see
  .github/workflows/windows-tests.yml); the scripts under test read those variables.
#>
$ErrorActionPreference = "Stop"

$Root     = 'C:\cwm-test'
$Src      = 'C:\cwm-test\a\app'
$Dst      = 'C:\cwm-test\b\app'
$OldSlug  = 'c-cwm-test-a-app'
$NewSlug  = 'c-cwm-test-b-app'
$OldWs    = 'a' * 32
$NewWs    = 'b' * 32
$OtherWs  = 'c' * 32
$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$AutoMigrate = Join-Path $RepoRoot 'scripts\auto-migrate.ps1'
$Verify      = Join-Path $RepoRoot 'scripts\verify-migration.ps1'
$Fixture     = Join-Path $PSScriptRoot 'cursor_fixture.py'
$Projects    = Join-Path $env:USERPROFILE '.cursor\projects'
$PsExe       = (Get-Process -Id $PID).Path

foreach ($v in 'APPDATA', 'USERPROFILE') {
    $val = [Environment]::GetEnvironmentVariable($v)
    if (-not $val -or -not $val.StartsWith("$Root\fake\", [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to run: $v must point under $Root\fake\ (got '$val')"
    }
}

$script:Failures = 0
function Assert-That {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { Write-Host "  [PASS] $Name" -ForegroundColor Green }
    else {
        $script:Failures++
        Write-Host "  [FAIL] $Name $Detail" -ForegroundColor Red
    }
}

function Invoke-Script {
    # Runs a script in a child process of the same PowerShell edition and
    # returns its exit code and combined output.
    param([string]$Path, [string[]]$Arguments)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $PsExe -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2>&1 |
            ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    $text = $out -join "`n"
    Write-Host ($text -replace '(?m)^', '    | ')
    return [pscustomobject]@{ ExitCode = $code; Output = $text }
}

function Get-TreeSnapshot {
    # Every file/dir under C:\cwm-test with a content hash; any write shows up as a diff.
    Get-ChildItem $Root -Recurse -Force | Sort-Object FullName | ForEach-Object {
        if ($_.PSIsContainer) { "D $($_.FullName)" }
        else { "F $($_.FullName) $((Get-FileHash $_.FullName -Algorithm SHA256).Hash)" }
    }
}

function Get-DirManifest {
    param([string]$Dir)
    Get-ChildItem $Dir -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
        "$($_.FullName.Substring($Dir.Length)) $((Get-FileHash $_.FullName -Algorithm SHA256).Hash)"
    }
}

function Get-CursorState {
    $json = python $Fixture dump
    if ($LASTEXITCODE -ne 0) { throw "cursor_fixture.py dump failed" }
    return ($json -join "`n") | ConvertFrom-Json
}

function Test-SameList {
    param($A, $B)
    return ((@($A) -join "`n") -ceq (@($B) -join "`n"))
}

Write-Host "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)) at $PsExe"

# --- Fixture -------------------------------------------------------------
if (Test-Path $Root) { Remove-Item $Root -Recurse -Force }
New-Item -ItemType Directory -Force -Path "$Src\src", $env:APPDATA, $Projects | Out-Null
Set-Content -Path "$Src\README.md" -Value "# app" -Encoding Ascii
Set-Content -Path "$Src\src\main.txt" -Value "print('hi')" -Encoding Ascii
# Non-ASCII file name (zazolc.txt with Polish letters), built from code points
$plName = "za" + [char]0x017C + [char]0x00F3 + [char]0x0142 + [char]0x0107 + ".txt"
Set-Content -LiteralPath (Join-Path $Src $plName) -Value "pl" -Encoding Ascii
python $Fixture make $Src $Dst
if ($LASTEXITCODE -ne 0) { throw "cursor_fixture.py make failed" }
# The user copies the project files before migrating
New-Item -ItemType Directory -Force -Path (Split-Path $Dst -Parent) | Out-Null
Copy-Item $Src $Dst -Recurse

$oldSlugDir = Join-Path $Projects $OldSlug
$newSlugDir = Join-Path $Projects $NewSlug
$oldSlugManifest = Get-DirManifest $oldSlugDir

# --- Case 1: source == destination must fail and change nothing ------------
Write-Host "`n=== Case 1: source == destination ===" -ForegroundColor Cyan
foreach ($sameDst in @($Src, 'c:\CWM-TEST\A\APP\')) {
    $before = Get-TreeSnapshot
    $r = Invoke-Script $AutoMigrate @('-Source', $Src, '-Destination', $sameDst)
    Assert-That "exit code != 0 (dest '$sameDst')" ($r.ExitCode -ne 0) "exit=$($r.ExitCode)"
    Assert-That "error says 'same folder'" ($r.Output -match 'same folder')
    Assert-That "no file under $Root changed" (Test-SameList $before (Get-TreeSnapshot))
}

# --- Case 2: dry run ---------------------------------------------------
Write-Host "`n=== Case 2: -DryRun $Src -> $Dst ===" -ForegroundColor Cyan
$before = Get-TreeSnapshot
$r = Invoke-Script $AutoMigrate @('-Source', $Src, '-Destination', $Dst, '-DryRun')
Assert-That "exit code 0" ($r.ExitCode -eq 0) "exit=$($r.ExitCode)"
Assert-That "old slug detected as $OldSlug (exists)" ($r.Output -match "old project slug:\s+$OldSlug \(exists\)")
Assert-That "new slug detected as $NewSlug (not on disk yet)" ($r.Output -match "new project slug:\s+$NewSlug \(not on disk yet\)")
Assert-That "old workspace hash detected" ($r.Output -match "old workspace hash:\s+$OldWs")
Assert-That "new workspace hash detected" ($r.Output -match "new workspace hash:\s+$NewWs")
Assert-That "plans copy $OldSlug -> $NewSlug" ($r.Output -match "would copy slug $OldSlug -> $NewSlug")
Assert-That "no file under $Root changed" (Test-SameList $before (Get-TreeSnapshot))

# --- Case 3: real migration ------------------------------------------------
Write-Host "`n=== Case 3: migrate $Src -> $Dst ===" -ForegroundColor Cyan
$projectsBefore = @(Get-ChildItem $Projects -Directory | ForEach-Object Name | Sort-Object)
$decoyBefore = @('c-cwm-test-z-app', 'c-cwm-test-a-application' | ForEach-Object { Get-DirManifest (Join-Path $Projects $_) })
$r = Invoke-Script $AutoMigrate @('-Source', $Src, '-Destination', $Dst)
Assert-That "exit code 0" ($r.ExitCode -eq 0) "exit=$($r.ExitCode)"
Assert-That "old slug detected as $OldSlug" ($r.Output -match "old project slug:\s+$OldSlug \(exists\)")
Assert-That "new slug detected as $NewSlug" ($r.Output -match "new project slug:\s+$NewSlug \(not on disk yet\)")

$projectsAfter = @(Get-ChildItem $Projects -Directory | ForEach-Object Name | Sort-Object)
$added = @($projectsAfter | Where-Object { $_ -notin $projectsBefore })
Assert-That "exactly one new slug dir: $NewSlug" ((@($added) -join ',') -ceq $NewSlug) "added=[$($added -join ',')]"
Assert-That "no dir removed from .cursor\projects" (@($projectsBefore | Where-Object { $_ -notin $projectsAfter }).Count -eq 0)
Assert-That "no .bak-* slug dirs (nothing renamed away)" (@($projectsAfter | Where-Object { $_ -like '*.bak-*' }).Count -eq 0)
Assert-That "old slug untouched" (Test-SameList $oldSlugManifest (Get-DirManifest $oldSlugDir))
$newManifest = if (Test-Path $newSlugDir) { Get-DirManifest $newSlugDir } else { @() }
Assert-That "new slug = byte-identical copy of old slug (3 transcripts)" ((Test-SameList $oldSlugManifest $newManifest) -and @($newManifest).Count -eq 3) "new=[$($newManifest -join '; ')]"
$decoyAfter = @('c-cwm-test-z-app', 'c-cwm-test-a-application' | ForEach-Object { Get-DirManifest (Join-Path $Projects $_) })
Assert-That "decoy slugs (same basename / prefix) untouched" (Test-SameList $decoyBefore $decoyAfter)

$state = Get-CursorState
$heads = @(($state.global.'composer.composerHeaders' | ConvertFrom-Json).allComposers)
$byId = @{}; foreach ($h in $heads) { $byId[$h.composerId] = $h }
foreach ($cid in 'c1', 'c2') {
    $h = $byId[$cid]
    Assert-That "header $cid moved to new workspace" ($h -and $h.workspaceIdentifier.id -eq $NewWs) "ws=$($h.workspaceIdentifier.id)"
    Assert-That "header $cid uri.fsPath = $Dst" ($h -and $h.workspaceIdentifier.uri.fsPath -ceq $Dst) "fsPath=$($h.workspaceIdentifier.uri.fsPath)"
}
Assert-That "ghost c3 on new workspace removed" (-not $byId.ContainsKey('c3'))
Assert-That "other project's header c4 untouched" ($byId['c4'] -and $byId['c4'].workspaceIdentifier.id -eq $OtherWs)
Assert-That "named header c2 kept its non-ASCII name" ($byId['c2'] -and $byId['c2'].name -ceq ("Czat za" + [char]0x017C + [char]0x00F3 + [char]0x0142 + [char]0x0107))

$newWsState = $state.workspaces.$NewWs
$expectedUri = 'file:///c%3A/cwm-test/b/app'
Assert-That "new workspace.json folder is the URI Cursor writes ($expectedUri)" ($newWsState.folder -ceq $expectedUri) "folder=$($newWsState.folder)"
$items = ($newWsState.items | ConvertTo-Json -Compress -Depth 5)
Assert-That "new workspace state.vscdb copied from old (has editor memento)" ($items -match 'workbench\.editors')
Assert-That "new workspace state.vscdb mentions dest path" ($items -match [regex]::Escape('b\\\\app\\\\README.md'))
Assert-That "new workspace state.vscdb no longer mentions source path" ($items -notmatch [regex]::Escape('a\\\\app') -and $items -notmatch 'cwm-test/a/app')
Assert-That "old workspace.json still points at source" ($state.workspaces.$OldWs.folder -ceq 'file:///c%3A/cwm-test/a/app')

# --- Case 4: verify-migration.ps1 ------------------------------------------
Write-Host "`n=== Case 4: verify-migration.ps1 ===" -ForegroundColor Cyan
$r = Invoke-Script $Verify @('-Source', $Src, '-Destination', $Dst)
Assert-That "verify exit code 0" ($r.ExitCode -eq 0) "exit=$($r.ExitCode)"
Assert-That "verify reports CONFIDENCE: 100%" ($r.Output -match 'CONFIDENCE: 100%')
Assert-That "verify checked transcripts in $NewSlug" ($r.Output -match "slug=$NewSlug")
Assert-That "verify reports no FAIL lines" ($r.Output -notmatch '\[FAIL\]')

Write-Host ""
if ($script:Failures -gt 0) {
    Write-Host "E2E: $script:Failures assertion(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "E2E: all assertions PASS" -ForegroundColor Green
exit 0
