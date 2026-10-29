# Pester 5+ tests for project slug detection and the same-target guard.
# Run: Invoke-Pester ./tests
# Functions are loaded from the scripts via the AST, so the scripts' top-level
# code (which needs a real Cursor install) never runs.

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:AutoMigrate = Join-Path $RepoRoot "scripts/auto-migrate.ps1"
    $script:VerifyMigration = Join-Path $RepoRoot "scripts/verify-migration.ps1"

    function Get-FunctionSource {
        param([string]$Path)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $defs = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
        return ($defs | ForEach-Object { $_.Extent.Text }) -join "`n"
    }

    . ([scriptblock]::Create((Get-FunctionSource $AutoMigrate)))

    function New-ProjectSlugDir {
        param([string]$Slug)
        New-Item -ItemType Directory -Force -Path (Join-Path $env:USERPROFILE ".cursor/projects/$Slug") | Out-Null
    }
}

Describe "Get-ExpectedSlug" {
    It "derives <Expected> from <Path>" -ForEach @(
        @{ Path = 'C:\a\app';                                Expected = 'c-a-app' }
        @{ Path = 'D:\b\app\';                               Expected = 'd-b-app' }
        @{ Path = 'C:\Users\YOU\Desktop\Projects\MyProject'; Expected = 'c-Users-YOU-Desktop-Projects-MyProject' }
        @{ Path = 'C:\Users\YOU\Własne\app';                 Expected = 'c-Users-YOU-W-asne-app' }
        @{ Path = 'C:\x\New folder (51)';                    Expected = 'c-x-New-folder-51' }
        @{ Path = 'C:\Users\john.doe\my.app';                Expected = 'c-Users-john-doe-my-app' }
    ) {
        Get-ExpectedSlug $Path | Should -BeExactly $Expected
    }

    It "matches verify-migration.ps1's copy of the same rules" {
        $verifySrc = Get-FunctionSource $VerifyMigration
        foreach ($p in 'C:\a\app', 'C:\Users\YOU\Własne\app', 'C:\x\New folder (51)', 'C:\Users\john.doe\my.app') {
            $fromVerify = & { . ([scriptblock]::Create($verifySrc)); Get-ExpectedSlug $p }
            $fromVerify | Should -BeExactly (Get-ExpectedSlug $p)
        }
    }
}

Describe "Encode-FolderUri" {
    It "encodes <Path> the way Cursor writes workspace.json" -ForEach @(
        @{ Path = 'C:\cwm-test\b\app';          Expected = 'file:///c%3A/cwm-test/b/app' }
        @{ Path = 'D:\b\app\';                  Expected = 'file:///d%3A/b/app' }
        @{ Path = 'C:\x\New folder (51)';        Expected = 'file:///c%3A/x/New%20folder%20%2851%29' }
        @{ Path = "C:\x\it's done!*";            Expected = 'file:///c%3A/x/it%27s%20done%21%2A' }
        @{ Path = 'C:\Users\YOU\Własne\my.app'; Expected = 'file:///c%3A/Users/YOU/W%C5%82asne/my.app' }
    ) {
        Encode-FolderUri $Path | Should -BeExactly $Expected
    }

    It "round-trips through Normalize-FsPath" {
        foreach ($p in 'C:\cwm-test\b\app', 'C:\x\New folder (51)', 'C:\Users\YOU\Własne\my.app') {
            Normalize-FsPath (Encode-FolderUri $p) | Should -Be $p
        }
    }
}

Describe "verify-migration.ps1 Test-UriPointsTo" {
    BeforeAll {
        . ([scriptblock]::Create((Get-FunctionSource $VerifyMigration)))
    }

    It "accepts the destination's own URI" {
        Test-UriPointsTo 'file:///d%3A/b/app' 'D:\b\app' | Should -BeTrue
    }

    It "rejects a same-named folder under another parent" {
        Test-UriPointsTo 'file:///c%3A/a/app' 'D:\b\app' | Should -BeFalse
    }
}

Describe "Script file encoding" {
    It "<Name> has a UTF-8 BOM if it contains non-ASCII (Windows PowerShell 5.1 reads BOM-less files as ANSI)" -ForEach @(
        Get-ChildItem (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts'), $PSScriptRoot -Recurse -Filter *.ps1 |
            ForEach-Object { @{ Name = $_.Name; FullName = $_.FullName } }
    ) {
        $bytes = [System.IO.File]::ReadAllBytes($FullName)
        $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        $nonAscii = @($bytes | Where-Object { $_ -gt 0x7F }).Count -gt 0
        ($hasBom -or -not $nonAscii) | Should -BeTrue
    }
}

Describe "Find-ProjectSlug" {
    BeforeEach {
        $script:SavedProfile = $env:USERPROFILE
        $env:USERPROFILE = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Force -Path (Join-Path $env:USERPROFILE ".cursor/projects") | Out-Null
    }
    AfterEach {
        $env:USERPROFILE = $script:SavedProfile
    }

    It "does not return the old slug for a same-named folder under another parent" {
        New-ProjectSlugDir 'c-a-app'
        Find-ProjectSlug 'C:\a\app' | Should -BeExactly 'c-a-app'
        Find-ProjectSlug 'D:\b\app' | Should -BeExactly 'd-b-app'
    }

    It "returns distinct slugs when both exist" {
        New-ProjectSlugDir 'c-a-app'
        New-ProjectSlugDir 'd-b-app'
        Find-ProjectSlug 'C:\a\app' | Should -BeExactly 'c-a-app'
        Find-ProjectSlug 'D:\b\app' | Should -BeExactly 'd-b-app'
    }

    It "never matches on a basename substring" {
        New-ProjectSlugDir 'c-z-application'
        New-ProjectSlugDir 'c-z-app'
        Find-ProjectSlug 'C:\a\app' | Should -BeExactly 'c-a-app'
    }

    It "finds an existing slug for the full path when punctuation rules differ" {
        New-ProjectSlugDir 'c-w-my-app'
        Find-ProjectSlug 'C:\w\my_app' | Should -BeExactly 'c-w-my-app'
    }

    It "falls back to the predicted slug when the full-path match is ambiguous" {
        New-ProjectSlugDir 'c-w-my-app'
        New-ProjectSlugDir 'c-w-my--app'
        Find-ProjectSlug 'C:\w\my_app' | Should -BeExactly 'c-w-my_app'
    }
}

Describe "Assert-DistinctTargets" {
    It "rejects source == destination (case and trailing slash ignored)" {
        { Assert-DistinctTargets -SourceFolder 'C:\a\app' -DestFolder 'c:\A\app\' -OldSlug 'c-a-app' -NewSlug 'c-a-app' } |
            Should -Throw "*same folder*"
    }

    It "rejects identical old and new slugs" {
        { Assert-DistinctTargets -SourceFolder 'C:\a\app' -DestFolder 'D:\b\app' -OldSlug 'c-a-app' -NewSlug 'C-A-APP' } |
            Should -Throw "*slug are the same*"
    }

    It "rejects a missing new slug" {
        { Assert-DistinctTargets -SourceFolder 'C:\a\app' -DestFolder 'D:\b\app' -OldSlug 'c-a-app' -NewSlug '' } |
            Should -Throw "*new project slug*"
    }

    It "accepts same-named folders under different parents" {
        { Assert-DistinctTargets -SourceFolder 'C:\a\app' -DestFolder 'D:\b\app' -OldSlug 'c-a-app' -NewSlug 'd-b-app' } |
            Should -Not -Throw
    }
}

Describe "auto-migrate.ps1 -DryRun end to end" {
    It "stops with a clear error when source == destination and touches nothing" {
        $home_ = Join-Path $TestDrive "e2e-home"
        $app = Join-Path $TestDrive "e2e/a/app"
        New-Item -ItemType Directory -Force -Path $app | Out-Null
        $projects = Join-Path $home_ ".cursor/projects"
        # Non-Windows path: Get-ExpectedSlug returns $null, so seed the full-path fallback
        $slugDir = Join-Path $projects (Get-SlugKey (Resolve-Path $app).Path)
        New-Item -ItemType Directory -Force -Path (Join-Path $slugDir "agent-transcripts") | Out-Null
        $before = @(Get-ChildItem $projects -Recurse | ForEach-Object FullName)

        $pwshExe = (Get-Process -Id $PID).Path
        $saved = $env:USERPROFILE, $env:APPDATA
        try {
            $env:USERPROFILE = $home_
            $env:APPDATA = Join-Path $TestDrive "e2e-appdata"
            # Windows PowerShell 5.1 turns the child's stderr into terminating errors under Stop
            $ErrorActionPreference = 'Continue'
            $out = & $pwshExe -NoProfile -File $AutoMigrate -Source $app -Destination $app -DryRun 2>&1 | Out-String
        } finally {
            $env:USERPROFILE, $env:APPDATA = $saved
        }

        $LASTEXITCODE | Should -Not -Be 0
        $out | Should -Match "same folder"
        @(Get-ChildItem $projects -Recurse | ForEach-Object FullName) | Should -Be $before
    }
}
