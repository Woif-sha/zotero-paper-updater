[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) `
    "scripts\ZoteroPaperUpdater.DuplicateConsolidation.psm1"
$identityPath = Join-Path (Split-Path -Parent $PSScriptRoot) `
    "scripts\ZoteroPaperUpdater.DuplicateIdentity.psm1"
Import-Module $identityPath -Force -DisableNameChecking
Import-Module $modulePath -Force -DisableNameChecking

$passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:passed++
}

function New-ConsolidationMember {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Constructs an in-memory test fixture and does not change external state."
    )]
    param(
        [string]$Key,
        [string]$Doi = "10.1000/paper",
        [string]$Title = "A Paper",
        [string[]]$Creators = @("Ada Lovelace", "Alan Turing"),
        [string]$PublicationTitle = "Journal",
        [string]$Date = "2024",
        [string[]]$Tags = @(),
        [int[]]$Collections = @(),
        [hashtable]$Relations = @{},
        [string[]]$Notes = @(),
        [string[]]$UnknownChildren = @(),
        [bool]$HasAnnotations = $false,
        [bool]$IsFinal = $false,
        [bool]$CacheHealthy = $true,
        [bool]$CacheComplete = $true,
        [string]$FullMdSha256 = "MD-HASH",
        [string]$ParsedAt = "2026-01-01T00:00:00Z",
        [string]$DateAdded = "2025-01-01T00:00:00Z"
    )

    [pscustomobject][ordered]@{
        parent = [pscustomobject][ordered]@{
            key = $Key
            version = if ($Key -eq "P1") { 7 } else { 9 }
            doi = $Doi
            title = $Title
            creators = $Creators
            publicationTitle = $PublicationTitle
            date = $Date
            dateAdded = $DateAdded
            tags = $Tags
            collections = $Collections
            relations = [pscustomobject]$Relations
            notes = $Notes
            unknownChildren = $UnknownChildren
            inboundRelations = @()
        }
        attachment = [pscustomobject][ordered]@{
            key = "A$Key"
            version = 3
            hasAnnotations = $HasAnnotations
            isFinal = $IsFinal
        }
        storage = [pscustomobject]@{ path = "storage-$Key"; sha256 = "PDF-$Key" }
        cache = [pscustomobject][ordered]@{
            path = "cache-$Key"
            healthy = $CacheHealthy
            complete = $CacheComplete
            fullMdSha256 = $FullMdSha256
            parsedAt = $ParsedAt
        }
        local = [pscustomobject]@{ path = "local-$Key.pdf"; sha256 = "PDF-$Key" }
    }
}

$doiDecision = Get-DuplicateConsolidationDecision -GroupSnapshot ([pscustomobject]@{
    members = @(
        (New-ConsolidationMember -Key "P1" -Doi "https://doi.org/10.1000/PAPER"),
        (New-ConsolidationMember -Key "P2" -Doi "10.1000/paper")
    )
})
Assert-True ($doiDecision.status -eq "eligible") "canonical DOI equality should establish strict identity"
Assert-True ($doiDecision.identity.kind -eq "doi") "DOI identity should be recorded in proof"

$doiConflict = Get-DuplicateConsolidationDecision -GroupSnapshot ([pscustomobject]@{
    members = @(
        (New-ConsolidationMember -Key "P1" -Doi "10.1000/one"),
        (New-ConsolidationMember -Key "P2" -Doi "10.1000/two")
    )
})
Assert-True ($doiConflict.status -eq "blocked") "conflicting DOI values must block consolidation"

$metadataDecision = Get-DuplicateConsolidationDecision -GroupSnapshot ([pscustomobject]@{
    members = @(
        (New-ConsolidationMember -Key "P1" -Doi "" -Title "  A   PAPER "),
        (New-ConsolidationMember -Key "P2" -Doi "" -Title "a paper")
    )
})
Assert-True ($metadataDecision.status -eq "eligible") "complete normalized metadata plus equal healthy Markdown should establish identity"
Assert-True ($metadataDecision.identity.kind -eq "metadata_and_mineru") "metadata identity proof should name MinerU confirmation"

$creatorOrderConflict = Get-DuplicateConsolidationDecision -GroupSnapshot ([pscustomobject]@{
    members = @(
        (New-ConsolidationMember -Key "P1" -Doi ""),
        (New-ConsolidationMember -Key "P2" -Doi "" -Creators @("Alan Turing", "Ada Lovelace"))
    )
})
Assert-True ($creatorOrderConflict.status -eq "blocked") "ordered creator mismatch must block identity"

$sameTitleDifferentCreatorA = New-ConsolidationMember -Key "P1" -Doi ""
$sameTitleDifferentCreatorB = New-ConsolidationMember `
    -Key "P2" `
    -Doi "" `
    -Creators @("Different Creator")
Assert-True `
    ((Get-DuplicateDiscoveryKey -Member $sameTitleDifferentCreatorA) -cne
        (Get-DuplicateDiscoveryKey -Member $sameTitleDifferentCreatorB)) `
    "strict discovery keys should split same-title heterogeneous works before group decisions"

$selection = Get-DuplicateConsolidationDecision -GroupSnapshot ([pscustomobject]@{
    members = @(
        (New-ConsolidationMember `
            -Key "P1" `
            -Tags @("one") `
            -DateAdded "2020-01-01T00:00:00Z" `
            -IsFinal $true `
            -ParsedAt "2025-01-01T00:00:00Z"),
        (New-ConsolidationMember `
            -Key "P2" `
            -Tags @("two", "three") `
            -Collections @(4) `
            -Relations @{ "dc:relation" = @("zotero://select/items/P3") } `
            -DateAdded "2024-01-01T00:00:00Z" `
            -ParsedAt "2026-01-01T00:00:00Z")
    )
})
Assert-True ($selection.retainedParent.key -eq "P2") "parent with more distinct user state and external relations should win"
Assert-True ($selection.retainedAttachment.key -eq "AP1") "explicit formal final attachment should outrank a newer parse"
Assert-True (@($selection.mergedState.tags).Count -eq 3) "tags should be an exact union"
Assert-True (@($selection.mergedState.collections).Count -eq 1) "collections should be an exact union"
Assert-True ($selection.parentWriteRequest.expectedVersion -eq 9) "parent consolidation must carry the selected live version"

$typedTagMembers = @(
    New-ConsolidationMember -Key "P1"
    New-ConsolidationMember -Key "P2"
)
$typedTagMembers[0].parent.tags = @([pscustomobject]@{ tag = "shared"; type = 0 })
$typedTagMembers[1].parent.tags = @([pscustomobject]@{ tag = "shared"; type = 1 })
$typedTagDecision = Get-DuplicateConsolidationDecision -GroupSnapshot ([pscustomobject]@{
    members = $typedTagMembers
})
Assert-True ($typedTagDecision.status -eq "blocked") "the same tag with conflicting assignment types cannot be represented losslessly"
Assert-True ($typedTagDecision.issue.code -eq "duplicate_tag_type_conflict") "tag type conflict should have a typed blocker"

$tie = Get-DuplicateConsolidationDecision -GroupSnapshot ([pscustomobject]@{
    members = @(
        (New-ConsolidationMember -Key "P1" -DateAdded "2020-01-01T00:00:00Z"),
        (New-ConsolidationMember -Key "P2" -DateAdded "2021-01-01T00:00:00Z")
    )
})
Assert-True ($tie.retainedParent.key -eq "P1") "parent ties should retain the earliest dateAdded"

$annotated = Get-DuplicateConsolidationDecision -GroupSnapshot ([pscustomobject]@{
    members = @(
        (New-ConsolidationMember -Key "P1" -HasAnnotations $true),
        (New-ConsolidationMember -Key "P2" -IsFinal $true)
    )
})
Assert-True ($annotated.retainedAttachment.key -eq "AP1") "an attachment with non-migratable annotations has highest priority"

$splitAnnotations = Get-DuplicateConsolidationDecision -GroupSnapshot ([pscustomobject]@{
    members = @(
        (New-ConsolidationMember -Key "P1" -HasAnnotations $true),
        (New-ConsolidationMember -Key "P2" -HasAnnotations $true)
    )
})
Assert-True ($splitAnnotations.status -eq "blocked") "annotations spread across attachments must block the group"

$distinctNotes = Get-DuplicateConsolidationDecision -GroupSnapshot ([pscustomobject]@{
    members = @(
        (New-ConsolidationMember -Key "P1" -Notes @("retained note") -Tags @("one")),
        (New-ConsolidationMember -Key "P2" -Notes @("losing note"))
    )
})
Assert-True ($distinctNotes.status -eq "blocked") "distinct notes on a losing parent must block lossless consolidation"

$unknownChild = Get-DuplicateConsolidationDecision -GroupSnapshot ([pscustomobject]@{
    members = @(
        (New-ConsolidationMember -Key "P1"),
        (New-ConsolidationMember -Key "P2" -UnknownChildren @("CHILD-X"))
    )
})
Assert-True ($unknownChild.status -eq "blocked") "unknown losing-side child state must block cleanup"

$sameKeyRelationMembers = @(
    New-ConsolidationMember `
        -Key "P1" `
        -Relations @{ "dc:relation" = @("zotero://select/library/items/P2") } `
        -DateAdded "2020-01-01T00:00:00Z"
    New-ConsolidationMember -Key "P2" -DateAdded "2021-01-01T00:00:00Z"
)
$sameKeyRelationMembers[1].parent.inboundRelations = @([pscustomobject]@{
    sourceKey = "P1"
    sourceVersion = 7
    predicate = "dc:relation"
    oldTargetValue = "zotero://select/library/items/P2"
})
$sameKeyRelationDecision = Get-DuplicateConsolidationDecision -GroupSnapshot ([pscustomobject]@{
    members = $sameKeyRelationMembers
})
Assert-True (@($sameKeyRelationDecision.inboundRelationWrites).Count -eq 0) "retained-parent inbound rewrite should merge into its single parent mutation"
Assert-True ($sameKeyRelationDecision.parentWriteRequest.relations."dc:relation"[0] -eq "zotero://select/library/items/P1") "retained-parent relation proof should contain the rewritten final URI"

$threeMemberDecision = Get-DuplicateConsolidationDecision -GroupSnapshot ([pscustomobject]@{
    members = @(
        (New-ConsolidationMember -Key "P1" -DateAdded "2020-01-01T00:00:00Z"),
        (New-ConsolidationMember -Key "P2" -DateAdded "2021-01-01T00:00:00Z"),
        (New-ConsolidationMember -Key "P3" -DateAdded "2022-01-01T00:00:00Z")
    )
})
Assert-True ($threeMemberDecision.status -eq "eligible") "a fully proven three-member group should be one decision"
Assert-True (@($threeMemberDecision.losingParentKeys).Count -eq 2) "the group decision should bind every redundant parent"

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("zpu-consolidation-" + [guid]::NewGuid().ToString("N"))
try {
    $scope = [pscustomobject]@{
        paperRoot = Join-Path $tempRoot "papers"
        zoteroDataDir = Join-Path $tempRoot "zotero"
    }
    $storageRoot = Join-Path $scope.zoteroDataDir "storage"
    $cacheRoot = Join-Path $scope.zoteroDataDir "llm-for-zotero-mineru"
    foreach ($path in @($scope.paperRoot, $storageRoot, $cacheRoot)) {
        [IO.Directory]::CreateDirectory($path) | Out-Null
    }
    $groupMembers = @(
        New-ConsolidationMember -Key "P1" -Tags @("one") -DateAdded "2020-01-01T00:00:00Z"
        New-ConsolidationMember -Key "P2" -Tags @("two") -DateAdded "2021-01-01T00:00:00Z"
        New-ConsolidationMember -Key "P3" -DateAdded "2022-01-01T00:00:00Z"
    )
    foreach ($member in $groupMembers) {
        $key = [string]$member.parent.key
        $member.storage.path = Join-Path $storageRoot $member.attachment.key
        $member.cache.path = Join-Path $cacheRoot $member.attachment.key
        $member.local.path = Join-Path $scope.paperRoot "$key.pdf"
        foreach ($path in @($member.storage.path, $member.cache.path)) {
            [IO.Directory]::CreateDirectory($path) | Out-Null
        }
        [IO.File]::WriteAllText($member.local.path, $key)
    }
    $state = [pscustomobject]@{
        applyCount = 0
        writeCount = 0
        applied = $false
        interruptAfterWrite = $true
        trash = @()
        purged = $false
    }
    $operations = [pscustomobject]@{
        ReadConsolidationMembers = {
            param($Decision)
            @($Decision.members)
        }
        ReadLiveState = {
            param($Plan)
            [pscustomobject][ordered]@{
                retain = $Plan.retain
                remove = $Plan.remove
                removals = @($Plan.removals)
            }
        }
        ReadAssetEvidence = {
            param($Plan, $Expected)
            $null = $Plan
            @($Expected)
        }
        ApplyConsolidation = {
            param($Decision)
            $null = $Decision
            $state.applyCount++
            if ($state.applied) {
                return [pscustomobject]@{ status = "already_applied" }
            }
            $state.applied = $true
            $state.writeCount++
            if ($state.interruptAfterWrite) {
                $state.interruptAfterWrite = $false
                throw "simulated interruption after atomic consolidation write"
            }
            [pscustomobject]@{ status = "written" }
        }
        GetTrashKeys = { @($state.trash) }
        GetLiveZoteroKeys = {
            param($Keys)
            if ($state.purged) { @() } else { @($Keys | Where-Object { $_ -cnotin $state.trash }) }
        }
        TrashZotero = {
            param($Keys)
            $state.trash = @($Keys)
        }
        GetExistingZoteroKeys = {
            param($Keys)
            if ($state.purged) { @() } else { @($Keys) }
        }
        PurgeZotero = {
            param($Keys)
            $null = $Keys
            $state.purged = $true
            $state.trash = @()
        }
        GetExistingPaths = {
            param($Kind, $Paths)
            $null = $Kind
            @($Paths | Where-Object { Test-Path -LiteralPath $_ })
        }
        RemoveStorage = {
            param($Paths)
            foreach ($path in $Paths) { Remove-Item -LiteralPath $path -Recurse -Force }
        }
        RemoveLocal = {
            param($Paths)
            foreach ($path in $Paths) { Remove-Item -LiteralPath $path -Force }
        }
        RemoveCache = {
            param($Paths)
            foreach ($path in $Paths) { Remove-Item -LiteralPath $path -Recurse -Force }
        }
    }
    $interruptionSurfaced = $false
    try {
        $null = Invoke-DuplicateConsolidationCleanup `
            -Scope $scope `
            -GroupSnapshots @([pscustomobject]@{ members = $groupMembers }) `
            -Operations $operations
    }
    catch {
        $interruptionSurfaced = $_.Exception.Message -match "simulated interruption"
    }
    Assert-True $interruptionSurfaced "an unexpected interruption should surface without being downgraded"
    Assert-True (@($state.trash).Count -eq 0) "no delete may begin before consolidation proof is persisted"
    $transactionPath = @(
        Get-ChildItem `
            -LiteralPath (Join-Path $scope.zoteroDataDir "zotero-paper-updater-transactions") `
            -File `
            -Filter "cleanup-v1-P1-P2-P3-*.json"
    )[0].FullName
    $originalTransactionJson = [IO.File]::ReadAllText($transactionPath)
    $tamperedPlan = $originalTransactionJson | ConvertFrom-Json -Depth 40
    $tamperedPlan.consolidationDecision.mergedState.tags = @("tampered")
    [IO.File]::WriteAllText(
        $transactionPath,
        ($tamperedPlan | ConvertTo-Json -Depth 40),
        [Text.UTF8Encoding]::new($false)
    )
    $applyBeforeTamper = $state.applyCount
    $tamperSurfaced = $false
    try {
        $null = Invoke-DuplicateConsolidationCleanup `
            -Scope $scope `
            -GroupSnapshots @([pscustomobject]@{ members = $groupMembers }) `
            -Operations $operations
    }
    catch {
        $tamperSurfaced = $_.Exception.Message -match "fingerprint"
    }
    Assert-True $tamperSurfaced "tampering with merged state proof must invalidate the plan"
    Assert-True ($state.applyCount -eq $applyBeforeTamper) "proof tampering must block before consolidation or deletion"
    [IO.File]::WriteAllText(
        $transactionPath,
        $originalTransactionJson,
        [Text.UTF8Encoding]::new($false)
    )
    $groupResult = Invoke-DuplicateConsolidationCleanup `
        -Scope $scope `
        -GroupSnapshots @([pscustomobject]@{ members = $groupMembers }) `
        -Operations $operations
    Assert-True ($groupResult.status -eq "succeeded") "a proven three-member group should complete as one transaction"
    Assert-True ($state.writeCount -eq 1) "resume should recognize expectedAfter without a second write"
    Assert-True (@($groupResult.actions | Where-Object category -eq "modified").Count -eq 1) "one group should report one modified action"
    Assert-True (@($groupResult.actions | Where-Object category -eq "deleted").Count -eq 1) "all redundant members should share one deleted action"
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

Write-Output "All $passed duplicate-consolidation assertions passed."
