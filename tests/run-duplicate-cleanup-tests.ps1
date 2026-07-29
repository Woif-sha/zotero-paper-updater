[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repoRoot "scripts\ZoteroPaperUpdater.DuplicateCleanup.psm1"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("zotero-duplicate-cleanup-test-" + [guid]::NewGuid().ToString("N"))
$passed = 0

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
    $script:passed++
}

function New-CleanupFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Creates isolated test fixtures under the per-run temporary directory."
    )]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$RetainDoi = "https://doi.org/10.1000/Example",
        [string]$RemoveDoi = "10.1000/example",
        [string]$RetainMarkdownHash = "MD-SAME",
        [string]$RemoveMarkdownHash = "MD-SAME",
        [bool]$RetainHealthy = $true,
        [bool]$RemoveHealthy = $true,
        [bool]$RemoveUserStateEmpty = $true,
        [string]$RemoveLocalOverride,
        [switch]$OverlapLocalPaths,
        [string]$FailAfter
    )

    $root = Join-Path $tempRoot $Name
    $paperRoot = Join-Path $root "papers"
    $zoteroDataDir = Join-Path $root "ZoteroData"
    $storageRoot = Join-Path $zoteroDataDir "storage"
    $cacheRoot = Join-Path $zoteroDataDir "llm-for-zotero-mineru"
    foreach ($directory in @(
        $paperRoot,
        (Join-Path $storageRoot "ATTACH11"),
        (Join-Path $storageRoot "ATTACH22"),
        (Join-Path $cacheRoot "11"),
        (Join-Path $cacheRoot "22")
    )) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    $retainStorage = Join-Path $storageRoot "ATTACH11\paper.pdf"
    $removeStorage = Join-Path $storageRoot "ATTACH22\paper.pdf"
    $retainLocal = Join-Path $paperRoot "retain.pdf"
    $removeLocal = if ([string]::IsNullOrWhiteSpace($RemoveLocalOverride)) {
        if ($OverlapLocalPaths) { $retainLocal } else { Join-Path $paperRoot "remove.pdf" }
    }
    else {
        $RemoveLocalOverride
    }
    foreach ($path in @($retainStorage, $removeStorage, $retainLocal)) {
        [IO.File]::WriteAllText($path, $path)
    }
    if ([string]::IsNullOrWhiteSpace($RemoveLocalOverride) -and -not $OverlapLocalPaths) {
        $removeParent = Split-Path -Parent $removeLocal
        [IO.Directory]::CreateDirectory($removeParent) | Out-Null
        [IO.File]::WriteAllText($removeLocal, $removeLocal)
    }

    $candidate = [pscustomobject][ordered]@{
        retain = [pscustomobject][ordered]@{
            parent = [pscustomobject][ordered]@{
                key = "PARENT11"; id = 11; version = 7; doi = $RetainDoi
                relations = [pscustomobject]@{ "dc:relation" = @("keep") }
                tags = @("important"); collections = @(3); childKeys = @("ATTACH11")
            }
            attachment = [pscustomobject][ordered]@{ key = "ATTACH11"; id = 111; version = 3 }
            storage = [pscustomobject][ordered]@{ path = $retainStorage; sha256 = "PDF-KEEP" }
            cache = [pscustomobject][ordered]@{
                path = Join-Path $cacheRoot "11"; fullMdSha256 = $RetainMarkdownHash
                healthy = $RetainHealthy; attachmentKey = "ATTACH11"; parentItemKey = "PARENT11"
            }
            local = [pscustomobject][ordered]@{ path = $retainLocal; sha256 = "PDF-KEEP" }
            userStateEmpty = $false
        }
        remove = [pscustomobject][ordered]@{
            parent = [pscustomobject][ordered]@{
                key = "PARENT22"; id = 22; version = 9; doi = $RemoveDoi
                relations = [pscustomobject]@{}; tags = @(); collections = @(); childKeys = @("ATTACH22")
            }
            attachment = [pscustomobject][ordered]@{ key = "ATTACH22"; id = 222; version = 4 }
            storage = [pscustomobject][ordered]@{ path = $removeStorage; sha256 = "PDF-REMOVE" }
            cache = [pscustomobject][ordered]@{
                path = Join-Path $cacheRoot "22"; fullMdSha256 = $RemoveMarkdownHash
                healthy = $RemoveHealthy; attachmentKey = "ATTACH22"; parentItemKey = "PARENT22"
            }
            local = [pscustomobject][ordered]@{ path = $removeLocal; sha256 = "PDF-REMOVE" }
            userStateEmpty = $RemoveUserStateEmpty
        }
    }
    $liveStateSource = [pscustomobject][ordered]@{
        retain = $candidate.retain
        remove = $candidate.remove
    }
    $liveState = [Management.Automation.PSSerializer]::Deserialize(
        [Management.Automation.PSSerializer]::Serialize($liveStateSource, 20)
    )
    $scope = [pscustomobject]@{
        mode = "all"; selector = $null; paperRoot = $paperRoot; zoteroDataDir = $zoteroDataDir
    }
    $state = [pscustomobject]@{
        candidate = $candidate
        liveState = $liveState
        trashKeys = @()
        liveKeys = @("ATTACH22", "PARENT22")
        paths = @{
            storage = @($removeStorage)
            cache = @($candidate.remove.cache.path)
            local = @($removeLocal)
        }
        calls = [Collections.Generic.List[string]]::new()
        failAfter = $FailAfter
        failed = $false
        assetDrift = $false
    }
    $findCandidates = { param($Scope, $Targets) $null = @($Scope, $Targets); @($state.candidate) }.GetNewClosure()
    $readLiveState = {
        param($Plan)
        $null = $Plan
        if (-not $state.failed -and $state.failAfter -eq "read") {
            $state.failed = $true
            throw "interrupted during preflight"
        }
        $state.liveState
    }.GetNewClosure()
    $getTrashKeys = { @($state.trashKeys) }.GetNewClosure()
    $trashZotero = {
        param($Keys)
        $state.calls.Add("trash")
        if (-not $state.failed -and $state.failAfter -eq "trash-first") {
            $state.trashKeys = @($Keys[0])
            $state.liveKeys = @($state.liveKeys | Where-Object { $_ -cne $Keys[0] })
            $state.failed = $true
            throw "interrupted after first trash item"
        }
        $state.trashKeys = @($state.trashKeys) + @($Keys)
        $state.liveKeys = @($state.liveKeys | Where-Object { $_ -cnotin @($Keys) })
        if (-not $state.failed -and $state.failAfter -eq "trash") {
            $state.failed = $true
            throw "interrupted after trash"
        }
    }.GetNewClosure()
    $getExistingZoteroKeys = {
        param($Keys)
        @(
            @($state.liveKeys) + @($state.trashKeys) |
                Where-Object { $_ -cin @($Keys) } |
                Sort-Object -Unique
        )
    }.GetNewClosure()
    $getLiveZoteroKeys = {
        param($Keys)
        @($state.liveKeys | Where-Object { $_ -cin @($Keys) })
    }.GetNewClosure()
    $readAssetEvidence = {
        param($Plan, $ExpectedEvidence)
        $null = $Plan
        @(
            foreach ($descriptor in @($ExpectedEvidence)) {
                $side = [string]$descriptor.side
                $kind = [string]$descriptor.kind
                $path = [string]$descriptor.value.path
                $exists = if ($side -eq "retain") {
                    Test-Path -LiteralPath $path
                }
                else {
                    $path -cin @($state.paths[$kind])
                }
                if (-not $exists) { continue }
                $value = [Management.Automation.PSSerializer]::Deserialize(
                    [Management.Automation.PSSerializer]::Serialize($descriptor.value, 20)
                )
                if ($state.assetDrift -and $side -eq "remove" -and $kind -eq "local") {
                    $value.sha256 = "DRIFTED"
                }
                [pscustomobject][ordered]@{
                    side = $side
                    kind = $kind
                    value = $value
                }
            }
        )
    }.GetNewClosure()
    $purgeZotero = {
        param($Keys)
        $null = $Keys
        $state.calls.Add("purge")
        $state.liveKeys = @()
        $state.trashKeys = @()
        if (-not $state.failed -and $state.failAfter -eq "purge") {
            $state.failed = $true
            throw "interrupted after purge"
        }
    }.GetNewClosure()
    $getExistingPaths = {
        param($Kind, $Paths)
        @($state.paths[$Kind] | Where-Object { $_ -cin @($Paths) })
    }.GetNewClosure()
    $removeStorage = {
        param($Paths)
        $null = $Paths
        $state.calls.Add("storage")
        $state.paths.storage = @()
        if (-not $state.failed -and $state.failAfter -eq "storage") {
            $state.failed = $true
            throw "interrupted after storage"
        }
    }.GetNewClosure()
    $removeCache = {
        param($Paths)
        $null = $Paths
        $state.calls.Add("cache")
        $state.paths.cache = @()
        if (-not $state.failed -and $state.failAfter -eq "cache") {
            $state.failed = $true
            throw "interrupted after cache"
        }
    }.GetNewClosure()
    $removeLocal = {
        param($Paths)
        $null = $Paths
        $state.calls.Add("local")
        $state.paths.local = @()
        if (-not $state.failed -and $state.failAfter -eq "local") {
            $state.failed = $true
            throw "interrupted after local"
        }
    }.GetNewClosure()
    [pscustomobject]@{
        scope = $scope
        candidate = $candidate
        state = $state
        operations = [pscustomobject]@{
            FindCandidates = $findCandidates
            ReadLiveState = $readLiveState
            GetTrashKeys = $getTrashKeys
            TrashZotero = $trashZotero
            GetExistingZoteroKeys = $getExistingZoteroKeys
            GetLiveZoteroKeys = $getLiveZoteroKeys
            PurgeZotero = $purgeZotero
            ReadAssetEvidence = $readAssetEvidence
            GetExistingPaths = $getExistingPaths
            RemoveStorage = $removeStorage
            RemoveCache = $removeCache
            RemoveLocal = $removeLocal
        }
    }
}

try {
    Import-Module -Name $modulePath -Force -DisableNameChecking
    $scope = [pscustomobject]@{
        mode = "all"
        selector = $null
        paperRoot = Join-Path $tempRoot "papers"
        zoteroDataDir = Join-Path $tempRoot "ZoteroData"
    }
    [IO.Directory]::CreateDirectory($scope.paperRoot) | Out-Null
    [IO.Directory]::CreateDirectory($scope.zoteroDataDir) | Out-Null

    $operations = [pscustomobject]@{
        FindCandidates = { param($Scope, $Targets) $null = @($Scope, $Targets); @() }
    }
    $result = Invoke-MinimalDuplicateCleanup -Scope $scope -Targets @() -Operations $operations
    Assert-True -Condition ($result.status -eq "succeeded") -Message "no eligible duplicate should be a successful no-op"
    Assert-True -Condition ($result.actions.Count -eq 0) -Message "a no-op should not fabricate a deletion action"

    $successful = New-CleanupFixture -Name "successful"
    $result = Invoke-MinimalDuplicateCleanup `
        -Scope $successful.scope `
        -Targets @([pscustomobject]@{ parentItemKey = "PARENT11" }) `
        -Operations $successful.operations
    Assert-True -Condition ($result.status -eq "succeeded") -Message "the strict minimal duplicate should complete"
    Assert-True -Condition ($result.actions.Count -eq 1) -Message "cleanup should aggregate one logical action"
    Assert-True -Condition ($result.actions[0].category -eq "deleted") -Message "the action category should be deleted"
    Assert-True -Condition ($null -eq $result.actions[0].after) -Message "the logical deletion action must have after=null"
    Assert-True -Condition ($result.actions[0].before.PSObject.Properties.Name.Count -eq 5) -Message "before should list every removed asset class"
    Assert-True -Condition (($successful.state.calls -join ",") -eq "trash,purge,storage,local,cache") -Message "destructive assets should be removed in the required order"
    Assert-True -Condition ($result.actions[0].before.cache.path -eq $successful.candidate.remove.cache.path) -Message "the removed cache should be recorded"
    Assert-True -Condition ($result.actions[0].before.cache.path -ne $successful.candidate.retain.cache.path) -Message "the healthy retained cache must not be selected"

    $transactionPath = Join-Path $successful.scope.zoteroDataDir `
        "zotero-paper-updater-transactions\cleanup-v1-PARENT11-PARENT22.json"
    $persistedText = [IO.File]::ReadAllText($transactionPath)
    $persisted = $persistedText | ConvertFrom-Json
    Assert-True -Condition ($persisted.schemaVersion -eq 1) -Message "cleanup plans should use schema v1"
    Assert-True -Condition ($persisted.stage -eq "completed") -Message "a completed transaction should persist its proof stage"
    Assert-True -Condition (-not $persistedText.Contains("backup")) -Message "the plan must not create or describe backup copies"
    Assert-True -Condition (@(Get-ChildItem -LiteralPath (Split-Path -Parent $transactionPath) -Filter "*.tmp").Count -eq 0) -Message "atomic persistence should not leave temporary files"

    $secondResult = Invoke-MinimalDuplicateCleanup `
        -Scope $successful.scope `
        -Targets @([pscustomobject]@{ parentItemKey = "PARENT11" }) `
        -Operations $successful.operations
    Assert-True -Condition ($secondResult.actions.Count -eq 0) -Message "a completed transaction should rerun as an idempotent no-op"
    Assert-True -Condition (($successful.state.calls -join ",") -eq "trash,purge,storage,local,cache") -Message "a completed rerun must not repeat destructive operations"

    foreach ($invalidCase in @(
        @{ name = "doi-mismatch"; arguments = @{ RemoveDoi = "10.1000/different" }; expected = "canonical DOI" },
        @{ name = "missing-doi"; arguments = @{ RemoveDoi = "" }; expected = "canonical DOI" },
        @{ name = "unhealthy-cache"; arguments = @{ RemoveHealthy = $false }; expected = "healthy MinerU" },
        @{ name = "markdown-mismatch"; arguments = @{ RemoveMarkdownHash = "MD-DIFFERENT" }; expected = "same work" },
        @{ name = "user-state"; arguments = @{ RemoveUserStateEmpty = $false }; expected = "user state" }
    )) {
        $fixtureArguments = $invalidCase.arguments
        $fixture = New-CleanupFixture -Name $invalidCase.name @fixtureArguments
        $blocked = Invoke-MinimalDuplicateCleanup `
            -Scope $fixture.scope `
            -Targets @([pscustomobject]@{ parentItemKey = "PARENT11" }) `
            -Operations $fixture.operations
        Assert-True -Condition ($blocked.status -eq "failed") -Message "$($invalidCase.name) should block cleanup"
        Assert-True -Condition ($blocked.issues[0].message -match $invalidCase.expected) -Message "$($invalidCase.name) should explain its invariant"
        Assert-True -Condition ($fixture.state.calls.Count -eq 0) -Message "$($invalidCase.name) must block before destructive work"
    }

    $outsidePath = Join-Path $tempRoot "outside-remove.pdf"
    $outside = New-CleanupFixture -Name "outside-path" -RemoveLocalOverride $outsidePath
    $blockedOutside = Invoke-MinimalDuplicateCleanup `
        -Scope $outside.scope `
        -Targets @([pscustomobject]@{ parentItemKey = "PARENT11" }) `
        -Operations $outside.operations
    Assert-True -Condition ($blockedOutside.status -eq "failed") -Message "a path outside PaperRoot should block cleanup"
    Assert-True -Condition ($outside.state.calls.Count -eq 0) -Message "path boundaries must be checked before destructive work"

    $overlap = New-CleanupFixture -Name "overlap-path" -OverlapLocalPaths
    $blockedOverlap = Invoke-MinimalDuplicateCleanup `
        -Scope $overlap.scope `
        -Targets @([pscustomobject]@{ parentItemKey = "PARENT11" }) `
        -Operations $overlap.operations
    Assert-True -Condition ($blockedOverlap.status -eq "failed") -Message "keep/delete asset paths must not overlap"
    Assert-True -Condition ($overlap.state.calls.Count -eq 0) -Message "overlapping assets must freeze before mutation"

    $drifted = New-CleanupFixture -Name "preflight-drift"
    $drifted.state.liveState.remove.parent.version = 10
    $driftBlocked = Invoke-MinimalDuplicateCleanup `
        -Scope $drifted.scope `
        -Targets @([pscustomobject]@{ parentItemKey = "PARENT11" }) `
        -Operations $drifted.operations
    Assert-True -Condition ($driftBlocked.status -eq "failed") -Message "version drift should block the first destructive operation"
    Assert-True -Condition ($drifted.state.calls.Count -eq 0) -Message "preflight drift must not mutate any asset"

    $extraTrash = New-CleanupFixture -Name "extra-trash"
    $extraTrash.state.trashKeys = @("UNRELATED")
    $trashBlocked = Invoke-MinimalDuplicateCleanup `
        -Scope $extraTrash.scope `
        -Targets @([pscustomobject]@{ parentItemKey = "PARENT11" }) `
        -Operations $extraTrash.operations
    Assert-True -Condition ($trashBlocked.status -eq "failed") -Message "unrelated Trash content should block cleanup"
    Assert-True -Condition ($extraTrash.state.calls.Count -eq 0) -Message "Trash must be exact before any deletion"

    foreach ($interruption in @("trash", "purge", "storage", "cache", "local")) {
        $fixture = New-CleanupFixture -Name "resume-$interruption" -FailAfter $interruption
        $firstRun = Invoke-MinimalDuplicateCleanup `
            -Scope $fixture.scope `
            -Targets @([pscustomobject]@{ parentItemKey = "PARENT11" }) `
            -Operations $fixture.operations
        Assert-True -Condition ($firstRun.status -eq "failed") -Message "$interruption interruption should surface as a blocked run"
        $resumed = Invoke-MinimalDuplicateCleanup `
            -Scope $fixture.scope `
            -Targets @([pscustomobject]@{ parentItemKey = "PARENT11" }) `
            -Operations $fixture.operations
        $resumeIssue = if (@($resumed.issues).Count -gt 0) {
            [string]$resumed.issues[0].message
        }
        else {
            ""
        }
        Assert-True -Condition ($resumed.status -eq "succeeded") -Message "$interruption interruption should resume safely: $resumeIssue"
        Assert-True -Condition ($resumed.actions.Count -eq 1) -Message "$interruption resume should emit one completed logical deletion"
        Assert-True -Condition (@($fixture.state.calls | Where-Object { $_ -eq $interruption }).Count -eq 1) -Message "$interruption operation must not be repeated after its effect is proven"
    }

    $plannedInterruption = New-CleanupFixture -Name "resume-planned" -FailAfter "read"
    $firstPlannedRun = Invoke-MinimalDuplicateCleanup `
        -Scope $plannedInterruption.scope `
        -Targets @([pscustomobject]@{ parentItemKey = "PARENT11" }) `
        -Operations $plannedInterruption.operations
    Assert-True -Condition ($firstPlannedRun.status -eq "failed") -Message "an interruption after planned persistence should surface"
    $resumedPlannedRun = Invoke-MinimalDuplicateCleanup `
        -Scope $plannedInterruption.scope `
        -Targets @([pscustomobject]@{ parentItemKey = "PARENT11" }) `
        -Operations $plannedInterruption.operations
    Assert-True -Condition ($resumedPlannedRun.status -eq "succeeded") -Message "a persisted planned stage should resume through fresh preflight"

    $partialTrash = New-CleanupFixture -Name "resume-partial-trash" -FailAfter "trash-first"
    $partialTrashFirst = Invoke-MinimalDuplicateCleanup `
        -Scope $partialTrash.scope `
        -Targets @([pscustomobject]@{ parentItemKey = "PARENT11" }) `
        -Operations $partialTrash.operations
    Assert-True -Condition ($partialTrashFirst.status -eq "failed") -Message "a first-item Trash interruption should surface"
    $partialTrashResume = Invoke-MinimalDuplicateCleanup `
        -Scope $partialTrash.scope `
        -Targets @([pscustomobject]@{ parentItemKey = "PARENT11" }) `
        -Operations $partialTrash.operations
    Assert-True -Condition ($partialTrashResume.status -eq "succeeded") -Message "a verified expected Trash subset should resume"
    Assert-True -Condition (@($partialTrash.state.calls | Where-Object { $_ -eq "trash" }).Count -eq 2) -Message "resume should trash only the remaining expected key"

    $tampered = New-CleanupFixture -Name "tampered-transaction" -FailAfter "trash-first"
    $null = Invoke-MinimalDuplicateCleanup `
        -Scope $tampered.scope `
        -Targets @([pscustomobject]@{ parentItemKey = "PARENT11" }) `
        -Operations $tampered.operations
    $tamperedPath = Join-Path $tampered.scope.zoteroDataDir `
        "zotero-paper-updater-transactions\cleanup-v1-PARENT11-PARENT22.json"
    $tamperedPlan = Get-Content -LiteralPath $tamperedPath -Raw | ConvertFrom-Json -Depth 30
    $tamperedPlan.remove.local.path = Join-Path $tempRoot "outside-tampered.pdf"
    [IO.File]::WriteAllText(
        $tamperedPath,
        ($tamperedPlan | ConvertTo-Json -Depth 30),
        [Text.UTF8Encoding]::new($false)
    )
    $callsBeforeTamperResume = $tampered.state.calls.Count
    $tamperResult = Invoke-MinimalDuplicateCleanup `
        -Scope $tampered.scope `
        -Targets @([pscustomobject]@{ parentItemKey = "PARENT11" }) `
        -Operations $tampered.operations
    Assert-True -Condition ($tamperResult.status -eq "failed") -Message "a tampered persisted plan must not drive recovery"
    Assert-True -Condition ($tampered.state.calls.Count -eq $callsBeforeTamperResume) -Message "transaction tampering must block before another mutation"

    $stageTampered = New-CleanupFixture -Name "tampered-stage" -FailAfter "trash-first"
    $null = Invoke-MinimalDuplicateCleanup `
        -Scope $stageTampered.scope `
        -Targets @([pscustomobject]@{ parentItemKey = "PARENT11" }) `
        -Operations $stageTampered.operations
    $stageTamperedPath = Join-Path $stageTampered.scope.zoteroDataDir `
        "zotero-paper-updater-transactions\cleanup-v1-PARENT11-PARENT22.json"
    $stageTamperedPlan = Get-Content -LiteralPath $stageTamperedPath -Raw |
        ConvertFrom-Json -Depth 30
    $stageTamperedPlan.stage = "zotero_purged"
    [IO.File]::WriteAllText(
        $stageTamperedPath,
        ($stageTamperedPlan | ConvertTo-Json -Depth 30),
        [Text.UTF8Encoding]::new($false)
    )
    $callsBeforeStageTamper = $stageTampered.state.calls.Count
    $stageTamperResult = Invoke-MinimalDuplicateCleanup `
        -Scope $stageTampered.scope `
        -Targets @([pscustomobject]@{ parentItemKey = "PARENT11" }) `
        -Operations $stageTampered.operations
    Assert-True -Condition ($stageTamperResult.status -eq "failed") -Message "a tampered transaction stage must not skip verified phases"
    Assert-True -Condition ($stageTampered.state.calls.Count -eq $callsBeforeStageTamper) -Message "stage tampering must block before path deletion"

    $hashDrift = New-CleanupFixture -Name "hash-drift" -FailAfter "trash-first"
    $null = Invoke-MinimalDuplicateCleanup `
        -Scope $hashDrift.scope `
        -Targets @([pscustomobject]@{ parentItemKey = "PARENT11" }) `
        -Operations $hashDrift.operations
    $hashDrift.state.assetDrift = $true
    $callsBeforeHashResume = $hashDrift.state.calls.Count
    $hashDriftResult = Invoke-MinimalDuplicateCleanup `
        -Scope $hashDrift.scope `
        -Targets @([pscustomobject]@{ parentItemKey = "PARENT11" }) `
        -Operations $hashDrift.operations
    Assert-True -Condition ($hashDriftResult.status -eq "failed") -Message "asset hash drift should block recovery"
    Assert-True -Condition ($hashDrift.state.calls.Count -eq $callsBeforeHashResume) -Message "hash drift must block before another mutation"

    $reparse = New-CleanupFixture -Name "reparse-path"
    Remove-Item -LiteralPath $reparse.candidate.remove.local.path -Force
    $outsideReparseRoot = Join-Path $tempRoot "reparse-outside"
    [IO.Directory]::CreateDirectory($outsideReparseRoot) | Out-Null
    $junctionPath = Join-Path $reparse.scope.paperRoot "linked"
    $null = New-Item -ItemType Junction -Path $junctionPath -Target $outsideReparseRoot
    $junctionFile = Join-Path $junctionPath "remove.pdf"
    [IO.File]::WriteAllText($junctionFile, "linked")
    $reparse.candidate.remove.local.path = $junctionFile
    $reparse.state.paths.local = @($junctionFile)
    $reparseResult = Invoke-MinimalDuplicateCleanup `
        -Scope $reparse.scope `
        -Targets @([pscustomobject]@{ parentItemKey = "PARENT11" }) `
        -Operations $reparse.operations
    Assert-True -Condition ($reparseResult.status -eq "failed") -Message "a reparse-point asset path should block cleanup"
    Assert-True -Condition ($reparse.state.calls.Count -eq 0) -Message "reparse-point paths must block before mutation"

    Write-Output "All $passed duplicate-cleanup assertions passed."
}
finally {
    $resolvedTempRoot = [IO.Path]::GetFullPath($tempRoot)
    $resolvedSystemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolvedTempRoot.StartsWith($resolvedSystemTemp, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
