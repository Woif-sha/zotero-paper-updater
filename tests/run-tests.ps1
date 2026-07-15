[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $PSScriptRoot
$resolverPath = Join-Path $scriptRoot "scripts\resolve-paper-md.ps1"
$auditPath = Join-Path $scriptRoot "scripts\audit-paper-links.ps1"
$skillSyncPath = Join-Path $scriptRoot "scripts\sync-global-skills-to-runtime.ps1"
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("zotero-paper-updater-test-" + [guid]::NewGuid().ToString("N"))
$zoteroData = Join-Path $tempRoot "ZoteroData"
$mineruRoot = Join-Path $zoteroData "llm-for-zotero-mineru"
$storageRoot = Join-Path $zoteroData "storage"
$paperRoot = Join-Path $tempRoot "papers"
$passed = 0

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
    $script:passed++
}

function Invoke-PowerShellScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & pwsh -NoProfile -File $Path @Arguments 2>&1
    [pscustomobject]@{
        exitCode = $LASTEXITCODE
        output = ($output | Out-String).Trim()
    }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [object]$Value
    )

    $parent = Split-Path -Parent $Path
    [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    [System.IO.File]::WriteAllText(
        $Path,
        ($Value | ConvertTo-Json -Depth 10),
        [System.Text.UTF8Encoding]::new($false)
    )
}

function New-CacheFixture {
    param(
        [Parameter(Mandatory = $true)]
        [int]$AttachmentId,
        [Parameter(Mandatory = $true)]
        [string]$AttachmentKey,
        [Parameter(Mandatory = $true)]
        [string]$ParentItemKey,
        [Parameter(Mandatory = $true)]
        [string]$Filename,
        [Parameter(Mandatory = $true)]
        [string]$Markdown
    )

    $cacheDir = Join-Path $mineruRoot ([string]$AttachmentId)
    [System.IO.Directory]::CreateDirectory($cacheDir) | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $cacheDir "full.md"),
        $Markdown,
        [System.Text.UTF8Encoding]::new($false)
    )
    Write-JsonFile -Path (Join-Path $cacheDir "_llm_source.json") -Value ([ordered]@{
        kind = "llm-for-zotero/mineru-cache-source"
        version = 2
        attachmentId = $AttachmentId
        attachmentKey = $AttachmentKey
        parentItemKey = $ParentItemKey
        sourceFilename = $Filename
        origin = "parsed"
        recordedAt = "2026-07-15T00:00:00.000Z"
        parsedAt = "2026-07-15T00:00:00.000Z"
    })
    Write-JsonFile -Path (Join-Path $cacheDir "manifest.json") -Value ([ordered]@{
        totalChars = $Markdown.Length
        sections = @([ordered]@{
            heading = "方法"
            charStart = 0
            charEnd = $Markdown.Length
        })
        figureBlocks = @()
    })
    Write-JsonFile -Path (Join-Path $cacheDir "content_list.json") -Value @()

    $storageDir = Join-Path $storageRoot $AttachmentKey
    [System.IO.Directory]::CreateDirectory($storageDir) | Out-Null
    $pdfBytes = [System.Text.Encoding]::ASCII.GetBytes("%PDF-test-$AttachmentKey")
    [System.IO.File]::WriteAllBytes((Join-Path $storageDir $Filename), $pdfBytes)

    [pscustomobject]@{
        cacheDir = $cacheDir
        storagePdf = Join-Path $storageDir $Filename
        pdfBytes = $pdfBytes
    }
}

try {
    [System.IO.Directory]::CreateDirectory($mineruRoot) | Out-Null
    [System.IO.Directory]::CreateDirectory($storageRoot) | Out-Null
    [System.IO.Directory]::CreateDirectory($paperRoot) | Out-Null

    $readmeText = [System.IO.File]::ReadAllText((Join-Path $scriptRoot "README.md"))
    $skillText = [System.IO.File]::ReadAllText((Join-Path $scriptRoot "SKILL.md"))
    Assert-True -Condition $readmeText.Contains("https://github.com/yilewang/llm-for-zotero") -Message "README should name the official upstream repository"
    Assert-True -Condition $skillText.Contains("check-llm-for-zotero-version.ps1 -RequireLatest") -Message "skill should require a live upstream version check"

    $globalSkillsRoot = Join-Path $tempRoot "global-skills"
    $runtimeRoot = Join-Path $zoteroData "agent-runtime"
    $runtimeSkillsA = Join-Path $runtimeRoot "profile-a\.agents\skills"
    $skillA = Join-Path $globalSkillsRoot "skill-a"
    [System.IO.Directory]::CreateDirectory($runtimeSkillsA) | Out-Null
    [System.IO.Directory]::CreateDirectory($skillA) | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $skillA "SKILL.md"),
        "---`nname: skill-a`ndescription: test`n---`n",
        [System.Text.UTF8Encoding]::new($false)
    )
    Write-JsonFile -Path (Join-Path $globalSkillsRoot ".skills-list.json") -Value ([ordered]@{
        version = 1
        skillsRoot = $globalSkillsRoot
        entries = [ordered]@{
            "skill-a" = [ordered]@{ path = $skillA; managed = $true; autoUpdate = $true }
        }
    })

    $firstSync = Invoke-PowerShellScript -Path $skillSyncPath -Arguments @(
        "-GlobalSkillsRoot", $globalSkillsRoot,
        "-RuntimeRoot", $runtimeRoot,
        "-AsJson"
    )
    Assert-True -Condition ($firstSync.exitCode -eq 0) -Message "runtime skill sync should succeed"
    $firstSyncResult = $firstSync.output | ConvertFrom-Json
    Assert-True -Condition ($firstSyncResult.createdLinkCount -eq 1) -Message "runtime skill sync should create one link"
    $runtimeSkillLinkA = Join-Path $runtimeSkillsA "skill-a"
    Assert-True -Condition ((Get-Item -LiteralPath $runtimeSkillLinkA -Force).LinkType -eq "SymbolicLink") -Message "runtime projection should be a directory symbolic link"

    $secondSync = Invoke-PowerShellScript -Path $skillSyncPath -Arguments @(
        "-GlobalSkillsRoot", $globalSkillsRoot,
        "-RuntimeRoot", $runtimeRoot,
        "-AsJson"
    )
    $secondSyncResult = $secondSync.output | ConvertFrom-Json
    Assert-True -Condition ($secondSyncResult.unchangedLinkCount -eq 1) -Message "runtime skill sync should be idempotent"

    $runtimeSkillsB = Join-Path $runtimeRoot "profile-b\.agents\skills"
    $skillB = Join-Path $globalSkillsRoot "skill-b"
    [System.IO.Directory]::CreateDirectory((Join-Path $runtimeSkillsB "skill-a")) | Out-Null
    [System.IO.Directory]::CreateDirectory($skillB) | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $skillB "SKILL.md"),
        "---`nname: skill-b`ndescription: test`n---`n",
        [System.Text.UTF8Encoding]::new($false)
    )
    Write-JsonFile -Path (Join-Path $globalSkillsRoot ".skills-list.json") -Value ([ordered]@{
        version = 1
        skillsRoot = $globalSkillsRoot
        entries = [ordered]@{
            "skill-a" = [ordered]@{ path = $skillA; managed = $true; autoUpdate = $true }
            "skill-b" = [ordered]@{ path = $skillB; managed = $true; autoUpdate = $true }
        }
    })
    $conflictingSync = Invoke-PowerShellScript -Path $skillSyncPath -Arguments @(
        "-GlobalSkillsRoot", $globalSkillsRoot,
        "-RuntimeRoot", $runtimeRoot,
        "-AsJson"
    )
    Assert-True -Condition ($conflictingSync.exitCode -eq 2) -Message "runtime skill sync should reject a real-directory conflict"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $runtimeSkillsA "skill-b"))) -Message "conflict preflight should prevent partial writes"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $runtimeSkillsB "skill-b"))) -Message "conflict preflight should be atomic across profiles"

    $markdown = "# 方法`r`n中文😀内容"
    $first = New-CacheFixture -AttachmentId 42 -AttachmentKey "ATTACH42" -ParentItemKey "PARENT1" -Filename "paper.pdf" -Markdown $markdown
    [System.IO.File]::WriteAllBytes((Join-Path $paperRoot "paper.pdf"), $first.pdfBytes)

    $resolver = Invoke-PowerShellScript -Path $resolverPath -Arguments @(
        "-ItemKey", "PARENT1",
        "-ZoteroDataDir", $zoteroData
    )
    Assert-True -Condition ($resolver.exitCode -eq 0) -Message "resolver should accept a unique parentItemKey"
    $resolved = $resolver.output | ConvertFrom-Json
    Assert-True -Condition ($resolved.attachmentKey -eq "ATTACH42") -Message "resolver should return the mapped attachmentKey"
    Assert-True -Condition ($resolved.health.fullMdUtf16Length -eq $markdown.Length) -Message "resolver should use UTF-16 string length"
    Assert-True -Condition $resolved.health.usableForMarkdownReading -Message "healthy cache should be readable"

    $oldDataDir = $env:ZOTERO_DATA_DIR
    $env:ZOTERO_DATA_DIR = $zoteroData
    try {
        $audit = Invoke-PowerShellScript -Path $auditPath -Arguments @(
            "-PaperRoot", $paperRoot,
            "-SkipApi",
            "-AllowIncomplete"
        )
    }
    finally {
        $env:ZOTERO_DATA_DIR = $oldDataDir
    }
    Assert-True -Condition ($audit.exitCode -eq 0) -Message "allow-incomplete audit should finish"
    $audited = $audit.output | ConvertFrom-Json
    Assert-True -Condition ($audited.summary.mappedRecordCount -eq 1) -Message "audit should map the local PDF by hash"
    Assert-True -Condition ($audited.records[0].fullMdPath -eq (Join-Path $first.cacheDir "full.md")) -Message "audit should expose the canonical full.md"

    $second = New-CacheFixture -AttachmentId 43 -AttachmentKey "ATTACH43" -ParentItemKey "PARENT1" -Filename "second.pdf" -Markdown "# Second"
    $ambiguous = Invoke-PowerShellScript -Path $resolverPath -Arguments @(
        "-ItemKey", "PARENT1",
        "-ZoteroDataDir", $zoteroData
    )
    Assert-True -Condition ($ambiguous.exitCode -eq 2) -Message "resolver should reject an ambiguous parentItemKey"
    $ambiguousResult = $ambiguous.output | ConvertFrom-Json
    Assert-True -Condition ($ambiguousResult.matchCount -eq 2) -Message "ambiguous result should list both matches"

    $allCachesAudit = Invoke-PowerShellScript -Path $auditPath -Arguments @(
        "-PaperRoot", $paperRoot,
        "-ZoteroDataDir", $zoteroData,
        "-SkipApi",
        "-RequireAllCaches",
        "-AllowIncomplete"
    )
    $allCachesResult = $allCachesAudit.output | ConvertFrom-Json
    Assert-True -Condition ($allCachesResult.summary.unmatchedCacheCount -eq 1) -Message "full-library mode should count caches with no local paper"
    Assert-True -Condition (@($allCachesResult.globalIssues | Where-Object { $_.code -eq "missing_local_pdf_for_cache" }).Count -eq 1) -Message "full-library mode should report the unmatched cache"

    $badManifest = [ordered]@{
        totalChars = $markdown.Length + 1
        sections = @()
        figureBlocks = @()
    }
    Write-JsonFile -Path (Join-Path $first.cacheDir "manifest.json") -Value $badManifest
    $invalid = Invoke-PowerShellScript -Path $resolverPath -Arguments @(
        "-ItemKey", "ATTACH42",
        "-ZoteroDataDir", $zoteroData
    )
    Assert-True -Condition ($invalid.exitCode -eq 2) -Message "resolver should reject a manifest character-count mismatch"
    $invalidResult = $invalid.output | ConvertFrom-Json
    Assert-True -Condition (@($invalidResult.issues | Where-Object { $_.code -eq "manifest_char_count_mismatch" }).Count -eq 1) -Message "resolver should identify the manifest mismatch"

    Write-Output "All $passed assertions passed."
}
finally {
    $resolvedTempRoot = [System.IO.Path]::GetFullPath($tempRoot)
    $resolvedSystemTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($resolvedTempRoot.StartsWith($resolvedSystemTemp, [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
