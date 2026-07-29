[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$adapterPath = Join-Path $repoRoot "scripts\ZoteroPaperUpdater.MaintenanceAdapters.psm1"
$adapter = Import-Module -Name $adapterPath -Force -PassThru -DisableNameChecking
$cleanupPath = Join-Path $repoRoot "scripts\ZoteroPaperUpdater.DuplicateCleanup.psm1"
$liveCleanupPath = Join-Path $repoRoot "scripts\ZoteroPaperUpdater.DuplicateCleanupLive.psm1"
Import-Module -Name $cleanupPath -Force -DisableNameChecking
Import-Module -Name $liveCleanupPath -Force -DisableNameChecking
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("zotero-live-duplicate-adapter-test-" + [guid]::NewGuid().ToString("N"))
$paperRoot = Join-Path $tempRoot "papers"
$zoteroDataDir = Join-Path $tempRoot "ZoteroData"
$passed = 0

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:passed++
}

function Write-JsonFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    [IO.File]::WriteAllText(
        $Path,
        ($Value | ConvertTo-Json -Depth 20),
        [Text.UTF8Encoding]::new($false)
    )
}

function Invoke-LiveAssetRecoveryCase {
    param([Parameter(Mandatory = $true)][string]$Kind)

    $caseRoot = Join-Path $tempRoot "recovery-$Kind"
    $casePaperRoot = Join-Path $caseRoot "papers"
    $caseZoteroDataDir = Join-Path $caseRoot "ZoteroData"
    [IO.Directory]::CreateDirectory($casePaperRoot) | Out-Null
    $caseItems = [Collections.Generic.List[object]]::new()
    $markdown = "# Same live recovery work`nBody"
    foreach ($number in @(55, 66)) {
        $parentKey = "RECOVERP$number"
        $attachmentKey = "RECOVERA$number"
        $storageDirectory = Join-Path $caseZoteroDataDir "storage\$attachmentKey"
        $cacheDirectory = Join-Path $caseZoteroDataDir "llm-for-zotero-mineru\$number"
        [IO.Directory]::CreateDirectory($storageDirectory) | Out-Null
        [IO.Directory]::CreateDirectory($cacheDirectory) | Out-Null
        $pdfBytes = [Text.Encoding]::ASCII.GetBytes("%PDF-recovery-$attachmentKey")
        [IO.File]::WriteAllBytes((Join-Path $storageDirectory "paper.pdf"), $pdfBytes)
        [IO.File]::WriteAllBytes((Join-Path $casePaperRoot "$attachmentKey.pdf"), $pdfBytes)
        [IO.File]::WriteAllText(
            (Join-Path $cacheDirectory "full.md"),
            $markdown,
            [Text.UTF8Encoding]::new($false)
        )
        Write-JsonFixture -Path (Join-Path $cacheDirectory "_llm_source.json") -Value ([ordered]@{
            kind = "llm-for-zotero/mineru-cache-source"
            version = 2
            attachmentId = $number
            attachmentKey = $attachmentKey
            parentItemKey = $parentKey
            origin = "parsed"
            recordedAt = "2026-07-30T00:00:00Z"
        })
        Write-JsonFixture -Path (Join-Path $cacheDirectory "manifest.json") -Value ([ordered]@{
            totalChars = $markdown.Length
            sections = @()
            figureBlocks = @()
        })
        Write-JsonFixture -Path (Join-Path $cacheDirectory "content_list.json") -Value @()
        $caseItems.Add([pscustomobject][ordered]@{
            key = $parentKey
            version = $number
            data = [pscustomobject][ordered]@{
                itemType = "journalArticle"
                DOI = "10.1000/live-asset-recovery"
                dateAdded = if ($number -eq 55) {
                    "2024-01-01T00:00:00Z"
                }
                else {
                    "2025-01-01T00:00:00Z"
                }
                tags = if ($number -eq 55) {
                    @([pscustomobject]@{ tag = "retain" })
                }
                else {
                    @()
                }
                collections = @()
                relations = [pscustomobject]@{}
            }
        })
        $caseItems.Add([pscustomobject][ordered]@{
            key = $attachmentKey
            version = $number + 1
            data = [pscustomobject][ordered]@{
                itemType = "attachment"
                parentItem = $parentKey
                contentType = "application/pdf"
                relations = [pscustomobject]@{}
            }
        })
    }
    $caseScope = [pscustomobject]@{
        mode = "all"
        selector = $null
        paperRoot = $casePaperRoot
        zoteroDataDir = $caseZoteroDataDir
    }
    $caseTargets = @(
        [pscustomobject]@{
            parentItemKey = "RECOVERP55"
            attachmentKey = "RECOVERA55"
            path = "stale-retain.pdf"
        },
        [pscustomobject]@{
            parentItemKey = "RECOVERP66"
            attachmentKey = "RECOVERA66"
            path = "stale-remove.pdf"
        }
    )
    $caseState = [pscustomobject]@{
        live = $caseItems
        trash = [Collections.Generic.List[object]]::new()
        removalCalls = [Collections.Generic.List[string]]::new()
    }
    $caseReadAll = {
        param($ReadScope)
        $null = $ReadScope
        @($caseState.live)
    }.GetNewClosure()
    $caseReadTrash = { @($caseState.trash) }.GetNewClosure()
    $caseMcp = {
        param($Arguments)
        if ([string]$Arguments.script -match "emptyTrash") {
            $caseState.trash.Clear()
        }
        else {
            foreach ($key in @("RECOVERA66", "RECOVERP66")) {
                $match = @($caseState.live | Where-Object { $_.key -ceq $key })[0]
                $null = $caseState.trash.Add($match)
                $null = $caseState.live.Remove($match)
            }
        }
        [pscustomobject]@{
            result = [pscustomobject]@{ isError = $false; content = @() }
        }
    }.GetNewClosure()
    $operations = Get-LiveDuplicateCleanupOperationTable `
        -Scope $caseScope `
        -ReadAllItems $caseReadAll `
        -ReadTrashItems $caseReadTrash `
        -McpAdapter $caseMcp
    $operationName = @{
        storage = "RemoveStorage"
        local = "RemoveLocal"
        cache = "RemoveCache"
    }[$Kind]
    $originalRemoval = $operations.$operationName
    $interrupted = $false
    $operations.$operationName = {
        param($Paths)
        & $originalRemoval $Paths
        $null = $caseState.removalCalls.Add($Kind)
        if (-not $interrupted) {
            $interrupted = $true
            throw "interrupted after live $Kind removal"
        }
    }.GetNewClosure()

    $first = Invoke-MinimalDuplicateCleanup `
        -Scope $caseScope `
        -Targets $caseTargets `
        -Operations $operations
    Assert-True -Condition ($first.status -eq "failed") -Message "$Kind live removal interruption should surface"
    $transactionPath = Join-Path $caseZoteroDataDir `
        "zotero-paper-updater-transactions\cleanup-v1-RECOVERP55-RECOVERP66.json"
    $persistedPlan = Get-Content -LiteralPath $transactionPath -Raw |
        ConvertFrom-Json -Depth 30
    $resumed = Invoke-ResumableCleanupTransaction `
        -CleanupPlan $persistedPlan `
        -TransactionPath $transactionPath `
        -Operations $operations
    Assert-True -Condition $resumed.completed -Message "$Kind live removal should resume"
    Assert-True -Condition ($null -ne $resumed.action) -Message "$Kind recovery should emit the deletion action"
    Assert-True -Condition ($caseState.removalCalls.Count -eq 1) -Message "$Kind live removal must not repeat"
}

try {
    [IO.Directory]::CreateDirectory($paperRoot) | Out-Null
    $items = [Collections.Generic.List[object]]::new()
    $markdown = "# Confirmed same work`nBody"
    foreach ($number in @(33, 44)) {
        $parentKey = "PRNT$number$number"
        $attachmentKey = "ATTACH$number"
        $storageDirectory = Join-Path $zoteroDataDir "storage\$attachmentKey"
        $cacheDirectory = Join-Path $zoteroDataDir "llm-for-zotero-mineru\$number"
        [IO.Directory]::CreateDirectory($storageDirectory) | Out-Null
        [IO.Directory]::CreateDirectory($cacheDirectory) | Out-Null
        $pdfBytes = [Text.Encoding]::ASCII.GetBytes("%PDF-$attachmentKey")
        [IO.File]::WriteAllBytes((Join-Path $storageDirectory "paper.pdf"), $pdfBytes)
        [IO.File]::WriteAllBytes((Join-Path $paperRoot "$attachmentKey.pdf"), $pdfBytes)
        [IO.File]::WriteAllText(
            (Join-Path $cacheDirectory "full.md"),
            $markdown,
            [Text.UTF8Encoding]::new($false)
        )
        Write-JsonFixture -Path (Join-Path $cacheDirectory "_llm_source.json") -Value ([ordered]@{
            kind = "llm-for-zotero/mineru-cache-source"
            version = 2
            attachmentId = $number
            attachmentKey = $attachmentKey
            parentItemKey = $parentKey
            origin = "parsed"
            recordedAt = "2026-07-29T00:00:00Z"
        })
        Write-JsonFixture -Path (Join-Path $cacheDirectory "manifest.json") -Value ([ordered]@{
            totalChars = $markdown.Length
            sections = @()
            figureBlocks = @()
        })
        Write-JsonFixture -Path (Join-Path $cacheDirectory "content_list.json") -Value @()
        $items.Add([pscustomobject][ordered]@{
            key = $parentKey
            version = $number
            data = [pscustomobject][ordered]@{
                itemType = "journalArticle"
                DOI = "10.1000/live-cleanup"
                dateAdded = if ($number -eq 33) { "2024-01-01T00:00:00Z" } else { "2025-01-01T00:00:00Z" }
                tags = if ($number -eq 33) { @([pscustomobject]@{ tag = "keep" }) } else { @() }
                collections = @()
                relations = [pscustomobject]@{}
            }
        })
        $items.Add([pscustomobject][ordered]@{
            key = $attachmentKey
            version = $number + 1
            data = [pscustomobject][ordered]@{
                itemType = "attachment"
                parentItem = $parentKey
                contentType = "application/pdf"
                relations = [pscustomobject]@{}
            }
        })
    }
    $scope = [pscustomobject]@{
        mode = "all"; selector = $null; paperRoot = $paperRoot; zoteroDataDir = $zoteroDataDir
    }
    $targets = @(
        [pscustomobject]@{ parentItemKey = "PRNT3333"; attachmentKey = "ATTACH33"; path = "stale-a.pdf" },
        [pscustomobject]@{ parentItemKey = "PRNT4444"; attachmentKey = "ATTACH44"; path = "stale-b.pdf" }
    )
    $state = [pscustomobject]@{
        live = $items
        trash = [Collections.Generic.List[object]]::new()
        calls = [Collections.Generic.List[string]]::new()
    }
    $readAll = {
        param($ReadScope)
        $null = $ReadScope
        @($state.live)
    }.GetNewClosure()
    $readTrash = { @($state.trash) }.GetNewClosure()
    $mcp = {
        param($Arguments)
        if ([string]$Arguments.script -match "emptyTrash") {
            $null = $state.calls.Add("purge")
            $state.trash.Clear()
        }
        else {
            $null = $state.calls.Add("trash")
            foreach ($key in @("ATTACH44", "PRNT4444")) {
                $match = @($state.live | Where-Object { $_.key -ceq $key })[0]
                $null = $state.trash.Add($match)
                $null = $state.live.Remove($match)
            }
        }
        [pscustomobject]@{ result = [pscustomobject]@{ isError = $false; content = @() } }
    }.GetNewClosure()

    $invalidCacheDirectory = Join-Path $zoteroDataDir "llm-for-zotero-mineru\invalid"
    [IO.Directory]::CreateDirectory($invalidCacheDirectory) | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $invalidCacheDirectory "_llm_source.json"),
        "{",
        [Text.UTF8Encoding]::new($false)
    )
    $invalidProvenance = & $adapter {
        param($ScopeValue, $TargetValues, $ReadAll, $ReadTrash, $Mcp)
        Invoke-MaintenanceCleanup `
            -Scope $ScopeValue `
            -Targets $TargetValues `
            -ReadAllItems $ReadAll `
            -ReadTrashItems $ReadTrash `
            -McpAdapter $Mcp
    } $scope $targets $readAll $readTrash $mcp
    Assert-True -Condition ($invalidProvenance.status -eq "failed") -Message "unreadable provenance should explicitly block cleanup"
    Assert-True -Condition ($invalidProvenance.issues[0].code -eq "cache_provenance_invalid") -Message "unreadable provenance should retain its blocking issue code"
    Assert-True -Condition ($state.calls.Count -eq 0) -Message "unreadable provenance must block before mutation"
    Remove-Item -LiteralPath $invalidCacheDirectory -Recurse -Force

    foreach ($attachmentState in @("tags", "relations")) {
        $statefulItems = [Management.Automation.PSSerializer]::Deserialize(
            [Management.Automation.PSSerializer]::Serialize(@($state.live), 20)
        )
        $removedAttachment = @($statefulItems | Where-Object { $_.key -eq "ATTACH44" })[0]
        if ($attachmentState -eq "tags") {
            $removedAttachment.data | Add-Member `
                -NotePropertyName "tags" `
                -NotePropertyValue @([pscustomobject]@{ tag = "keep-attachment-tag" })
        }
        else {
            $removedAttachment.data.relations = [pscustomobject]@{
                "dc:relation" = "keep-attachment-relation"
            }
        }
        $readStateful = {
            param($ReadScope)
            $null = $ReadScope
            @($statefulItems)
        }.GetNewClosure()
        $blockedState = & $adapter {
            param($ScopeValue, $TargetValues, $ReadAll, $ReadTrash, $Mcp)
            Invoke-MaintenanceCleanup `
                -Scope $ScopeValue `
                -Targets $TargetValues `
                -ReadAllItems $ReadAll `
                -ReadTrashItems $ReadTrash `
                -McpAdapter $Mcp
        } $scope $targets $readStateful $readTrash $mcp
        Assert-True -Condition ($blockedState.actions.Count -eq 0) -Message "removed attachment $attachmentState should block cleanup"
        Assert-True -Condition ($state.calls.Count -eq 0) -Message "attachment $attachmentState must block before mutation"
    }

    $result = & $adapter {
        param($ScopeValue, $TargetValues, $ReadAll, $ReadTrash, $Mcp)
        Invoke-MaintenanceCleanup `
            -Scope $ScopeValue `
            -Targets $TargetValues `
            -ReadAllItems $ReadAll `
            -ReadTrashItems $ReadTrash `
            -McpAdapter $Mcp
    } $scope $targets $readAll $readTrash $mcp

    Assert-True -Condition ($result.status -eq "succeeded") -Message "the live operation table should complete the minimal duplicate"
    Assert-True -Condition ($result.actions.Count -eq 1) -Message "the live adapter should emit one deletion action"
    Assert-True -Condition (($state.calls -join ",") -eq "trash,purge") -Message "Zotero writes should use trash then permanent purge"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $zoteroDataDir "storage\ATTACH44"))) -Message "the removed storage directory should be deleted"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $zoteroDataDir "llm-for-zotero-mineru\44"))) -Message "the removed cache should be deleted"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $paperRoot "ATTACH44.pdf"))) -Message "the freshly resolved local PDF should be deleted"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $paperRoot "ATTACH33.pdf")) -Message "the retained local PDF should remain"
    Assert-True -Condition ($result.actions[0].before.local.path -ne "stale-b.pdf") -Message "cleanup should rediscover live paths instead of trusting stale target paths"

    foreach ($assetKind in @("storage", "local", "cache")) {
        Invoke-LiveAssetRecoveryCase -Kind $assetKind
    }

    Write-Output "All $passed live-duplicate-cleanup-adapter assertions passed."
}
finally {
    $resolvedTempRoot = [IO.Path]::GetFullPath($tempRoot)
    $resolvedSystemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolvedTempRoot.StartsWith($resolvedSystemTemp, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
