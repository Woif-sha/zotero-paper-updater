Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "ZoteroPaperUpdater.Common.psm1") -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "ZoteroPaperUpdater.DuplicateIdentity.psm1") -DisableNameChecking

$script:TransactionSchemaVersion = 1
$script:TransactionStages = @(
    "planned",
    "preflighted",
    "consolidated",
    "trashed",
    "trash_verified",
    "zotero_purged",
    "storage_removed",
    "local_removed",
    "cache_removed",
    "completed"
)

function Invoke-CleanupOperation {
    param(
        [Parameter(Mandatory = $true)][object]$Operations,
        [Parameter(Mandatory = $true)][string]$Name,
        [object[]]$Arguments = @()
    )

    $property = $Operations.PSObject.Properties[$Name]
    if ($null -eq $property -or $property.Value -isnot [scriptblock]) {
        throw "Cleanup operation table must provide scriptblock '$Name'."
    }
    & $property.Value @Arguments
}

function Get-SortedUniqueString {
    param([AllowNull()][object[]]$Value)

    @(
        @($Value) |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
}

function Test-ExactStringSet {
    param(
        [AllowNull()][object[]]$Actual,
        [AllowNull()][object[]]$Expected
    )

    $actualValues = @(Get-SortedUniqueString -Value $Actual)
    $expectedValues = @(Get-SortedUniqueString -Value $Expected)
    if ($actualValues.Count -ne $expectedValues.Count) {
        return $false
    }
    for ($index = 0; $index -lt $actualValues.Count; $index++) {
        if (-not [string]::Equals(
            $actualValues[$index],
            $expectedValues[$index],
            [StringComparison]::Ordinal
        )) {
            return $false
        }
    }
    $true
}

function Get-RequiredNestedValue {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string[]]$Path
    )

    $current = $Object
    foreach ($name in $Path) {
        $current = Get-RequiredPropertyValue -Object $current -Name $name
    }
    $current
}

function Assert-DuplicateCleanupCandidate {
    param(
        [Parameter(Mandatory = $true)][object]$Candidate,
        [Parameter(Mandatory = $true)][object]$Scope
    )

    $retain = Get-RequiredPropertyValue -Object $Candidate -Name "retain"
    $candidateRemovals = Get-OptionalPropertyValue -Object $Candidate -Name "removals"
    $removals = if ($null -ne $candidateRemovals) {
        @($candidateRemovals)
    }
    else {
        @(Get-RequiredPropertyValue -Object $Candidate -Name "remove")
    }
    if ($removals.Count -lt 1) { throw "Duplicate cleanup requires at least one redundant member." }
    $remove = $removals[0]
    $retainParentKey = [string](Get-RequiredNestedValue -Object $retain -Path @("parent", "key"))
    $removeParentKeys = @(
        $removals | ForEach-Object {
            [string](Get-RequiredNestedValue -Object $_ -Path @("parent", "key"))
        }
    )
    if ([string]::IsNullOrWhiteSpace($retainParentKey) -or
        @($removeParentKeys | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0 -or
        $retainParentKey -cin $removeParentKeys -or
        @($removeParentKeys | Sort-Object -Unique).Count -ne $removeParentKeys.Count) {
        throw "A duplicate candidate must contain distinct existing parent items."
    }

    $retainDoi = ConvertTo-DuplicateDoi ([string](Get-RequiredNestedValue -Object $retain -Path @("parent", "doi")))
    $removeDoi = ConvertTo-DuplicateDoi ([string](Get-RequiredNestedValue -Object $remove -Path @("parent", "doi")))
    $consolidationDecision = Get-OptionalPropertyValue -Object $Candidate -Name "consolidationDecision"
    if ($null -eq $consolidationDecision) {
        if ([string]::IsNullOrWhiteSpace($retainDoi) -or $retainDoi -cne $removeDoi) {
            throw "Duplicate cleanup requires the same canonical DOI on both parent items."
        }
        foreach ($side in @($retain) + $removals) {
            if (-not [bool](Get-RequiredNestedValue -Object $side -Path @("cache", "healthy"))) {
                throw "Duplicate cleanup requires a healthy MinerU cache on both sides."
            }
        }
        $retainMarkdownHash = [string](Get-RequiredNestedValue -Object $retain -Path @("cache", "fullMdSha256"))
        $removeMarkdownHashes = @(
            $removals | ForEach-Object {
                [string](Get-RequiredNestedValue -Object $_ -Path @("cache", "fullMdSha256"))
            }
        )
        if ([string]::IsNullOrWhiteSpace($retainMarkdownHash) -or
            @($removeMarkdownHashes | Where-Object { $_ -cne $retainMarkdownHash }).Count -gt 0) {
            throw "Validated MinerU Markdown must confirm the same work."
        }
    }
    if ($null -eq $consolidationDecision -and @(
        $removals | Where-Object {
            -not [bool](Get-RequiredPropertyValue -Object $_ -Name "userStateEmpty")
        }
    ).Count -gt 0) {
        throw "The removed side contains user state that issue #13 cannot consolidate losslessly."
    }
    if ($null -ne $consolidationDecision -and
        [string](Get-RequiredPropertyValue -Object $consolidationDecision -Name "status") -cne
            "eligible") {
        throw "A cleanup plan cannot bind a blocked consolidation decision."
    }

    $pathRules = [Collections.Generic.List[object]]::new()
    $pathRules.Add(@("retain storage", (Get-RequiredNestedValue -Object $retain -Path @("storage", "path")), (Join-Path $Scope.zoteroDataDir "storage")))
    $pathRules.Add(@("retain cache", (Get-RequiredNestedValue -Object $retain -Path @("cache", "path")), (Join-Path $Scope.zoteroDataDir "llm-for-zotero-mineru")))
    $pathRules.Add(@("retain local", (Get-RequiredNestedValue -Object $retain -Path @("local", "path")), $Scope.paperRoot))
    foreach ($redundant in $removals) {
        $key = [string]$redundant.parent.key
        $pathRules.Add(@("remove $key storage", (Get-RequiredNestedValue -Object $redundant -Path @("storage", "path")), (Join-Path $Scope.zoteroDataDir "storage")))
        $pathRules.Add(@("remove $key cache", (Get-RequiredNestedValue -Object $redundant -Path @("cache", "path")), (Join-Path $Scope.zoteroDataDir "llm-for-zotero-mineru")))
        $pathRules.Add(@("remove $key local", (Get-RequiredNestedValue -Object $redundant -Path @("local", "path")), $Scope.paperRoot))
    }
    foreach ($rule in $pathRules) {
        $path = [IO.Path]::GetFullPath([string]$rule[1])
        $root = [IO.Path]::GetFullPath([string]$rule[2])
        if (-not (Test-PathWithinRoot -Path $path -Root $root)) {
            throw "$($rule[0]) path '$path' is outside its allowed root '$root'."
        }
        Assert-PathChainHasNoReparsePoint -Path $path
    }
    for ($leftIndex = 0; $leftIndex -lt $pathRules.Count; $leftIndex++) {
        for ($rightIndex = $leftIndex + 1; $rightIndex -lt $pathRules.Count; $rightIndex++) {
            $leftPath = [IO.Path]::GetFullPath([string]$pathRules[$leftIndex][1])
            $rightPath = [IO.Path]::GetFullPath([string]$pathRules[$rightIndex][1])
            if ((Test-PathWithinRoot -Path $leftPath -Root $rightPath) -or
                (Test-PathWithinRoot -Path $rightPath -Root $leftPath)) {
                throw "Cleanup asset paths overlap: '$leftPath' and '$rightPath'."
            }
        }
    }
}

function Get-CleanupBindingValue {
    param([Parameter(Mandatory = $true)][object]$Plan)

    $binding = [ordered]@{
        schemaVersion = Get-RequiredPropertyValue -Object $Plan -Name "schemaVersion"
        scope = Get-RequiredPropertyValue -Object $Plan -Name "scope"
        identity = Get-RequiredPropertyValue -Object $Plan -Name "identity"
        retain = Get-RequiredPropertyValue -Object $Plan -Name "retain"
        remove = Get-RequiredPropertyValue -Object $Plan -Name "remove"
        deleteKeys = @(Get-RequiredPropertyValue -Object $Plan -Name "deleteKeys")
    }
    $consolidationDecision = Get-OptionalPropertyValue -Object $Plan -Name "consolidationDecision"
    if ($null -ne $consolidationDecision) {
        $binding.consolidationDecision = $consolidationDecision
        $binding.removals = @(
            Get-RequiredPropertyValue -Object $Plan -Name "removals"
        )
    }
    [pscustomobject]$binding
}

function Get-CleanupFingerprint {
    param([Parameter(Mandatory = $true)][object]$Plan)

    $json = Get-CleanupBindingValue -Plan $Plan | ConvertTo-Json -Depth 30 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $sha = $null
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        [Convert]::ToHexString($sha.ComputeHash($bytes))
    }
    finally {
        if ($null -ne $sha) { $sha.Dispose() }
    }
}

function Get-CleanupStateFingerprint {
    param([Parameter(Mandatory = $true)][object]$Plan)

    $results = Get-RequiredPropertyValue -Object $Plan -Name "results"
    $resultProof = [ordered]@{}
    $proofNames = [Collections.Generic.List[string]]::new()
    $proofNames.AddRange([string[]]@(
        "preflightedAt",
        "trashedAt",
        "trashVerifiedAt",
        "zoteroPurgedAt",
        "storageRemovedAt",
        "localRemovedAt",
        "cacheRemovedAt",
        "completedAt"
    ))
    if ($null -ne (Get-OptionalPropertyValue -Object $results -Name "consolidatedAt")) {
        $proofNames.Insert(1, "consolidatedAt")
    }
    foreach ($name in $proofNames) {
        $resultProof[$name] = $null -ne (Get-RequiredPropertyValue -Object $results -Name $name)
    }
    $state = [pscustomobject][ordered]@{
        transactionId = Get-RequiredPropertyValue -Object $Plan -Name "transactionId"
        stage = Get-RequiredPropertyValue -Object $Plan -Name "stage"
        resultProof = [pscustomobject]$resultProof
        planFingerprint = Get-RequiredPropertyValue -Object $Plan -Name "planFingerprint"
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(
        ($state | ConvertTo-Json -Depth 10 -Compress)
    )
    $sha = $null
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        [Convert]::ToHexString($sha.ComputeHash($bytes))
    }
    finally {
        if ($null -ne $sha) { $sha.Dispose() }
    }
}

function ConvertTo-CleanupPlan {
    param(
        [Parameter(Mandatory = $true)][object]$Candidate,
        [Parameter(Mandatory = $true)][object]$Scope
    )

    Assert-DuplicateCleanupCandidate -Candidate $Candidate -Scope $Scope
    $retain = Get-RequiredPropertyValue -Object $Candidate -Name "retain"
    $remove = Get-RequiredPropertyValue -Object $Candidate -Name "remove"
    $candidateRemovals = Get-OptionalPropertyValue -Object $Candidate -Name "removals"
    $removals = if ($null -ne $candidateRemovals) { @($candidateRemovals) } else { @($remove) }
    $planValue = [ordered]@{
        schemaVersion = $script:TransactionSchemaVersion
        transactionId = [guid]::NewGuid().ToString()
        stage = "planned"
        scope = [pscustomobject][ordered]@{
            paperRoot = [IO.Path]::GetFullPath([string]$Scope.paperRoot)
            zoteroDataDir = [IO.Path]::GetFullPath([string]$Scope.zoteroDataDir)
        }
        identity = if ($null -ne (Get-OptionalPropertyValue -Object $Candidate -Name "consolidationDecision")) {
            (Get-RequiredPropertyValue -Object $Candidate.consolidationDecision -Name "identity")
        }
        else {
            [pscustomobject][ordered]@{
                doi = ConvertTo-DuplicateDoi ([string](Get-RequiredNestedValue -Object $retain -Path @("parent", "doi")))
                fullMdSha256 = [string](Get-RequiredNestedValue -Object $retain -Path @("cache", "fullMdSha256"))
            }
        }
        retain = $retain
        remove = $remove
        deleteKeys = @(
            $removals | ForEach-Object {
                [string](Get-RequiredNestedValue -Object $_ -Path @("attachment", "key"))
                [string](Get-RequiredNestedValue -Object $_ -Path @("parent", "key"))
            } | Sort-Object -Unique
        )
        results = [pscustomobject][ordered]@{
            preflightedAt = $null
            trashedAt = $null
            trashVerifiedAt = $null
            zoteroPurgedAt = $null
            storageRemovedAt = $null
            cacheRemovedAt = $null
            localRemovedAt = $null
            completedAt = $null
        }
    }
    $consolidationDecision = Get-OptionalPropertyValue -Object $Candidate -Name "consolidationDecision"
    if ($null -ne $consolidationDecision) {
        $planValue.consolidationDecision = $consolidationDecision
        $planValue.removals = @($removals)
        $planValue.results | Add-Member -NotePropertyName "consolidatedAt" -NotePropertyValue $null
    }
    $plan = [pscustomobject]$planValue
    $plan | Add-Member -NotePropertyName "planFingerprint" -NotePropertyValue (
        Get-CleanupFingerprint -Plan $plan
    )
    $plan | Add-Member -NotePropertyName "stateFingerprint" -NotePropertyValue (
        Get-CleanupStateFingerprint -Plan $plan
    )
    $plan
}

function Write-CleanupPlan {
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][string]$TransactionPath
    )

    $directory = Split-Path -Parent $TransactionPath
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $tempPath = Join-Path $directory (
        "." + [IO.Path]::GetFileName($TransactionPath) + "." +
        [guid]::NewGuid().ToString("N") + ".tmp"
    )
    try {
        [IO.File]::WriteAllText(
            $tempPath,
            ($Plan | ConvertTo-Json -Depth 30),
            [Text.UTF8Encoding]::new($false)
        )
        [IO.File]::Move($tempPath, $TransactionPath, $true)
    }
    finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force
        }
    }
}

function Set-CleanupStage {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Persists an internal transaction proof stage; callers own destructive authorization."
    )]
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$TransactionPath
    )

    if ($Stage -notin $script:TransactionStages) {
        throw "Unsupported cleanup stage '$Stage'."
    }
    $Plan.stage = $Stage
    $timestampProperty = @{
        preflighted = "preflightedAt"
        consolidated = "consolidatedAt"
        trashed = "trashedAt"
        trash_verified = "trashVerifiedAt"
        zotero_purged = "zoteroPurgedAt"
        storage_removed = "storageRemovedAt"
        cache_removed = "cacheRemovedAt"
        local_removed = "localRemovedAt"
        completed = "completedAt"
    }[$Stage]
    if ($null -ne $timestampProperty) {
        $Plan.results.$timestampProperty = (Get-Date).ToUniversalTime().ToString("o")
    }
    $Plan.stateFingerprint = Get-CleanupStateFingerprint -Plan $Plan
    Write-CleanupPlan -Plan $Plan -TransactionPath $TransactionPath
}

function Read-CleanupPlan {
    param(
        [Parameter(Mandatory = $true)][string]$TransactionPath,
        [Parameter(Mandatory = $true)][object]$ExpectedPlan
    )

    $plan = Get-Content -LiteralPath $TransactionPath -Raw | ConvertFrom-Json -Depth 30
    if ([int](Get-RequiredPropertyValue -Object $plan -Name "schemaVersion") -ne
        $script:TransactionSchemaVersion) {
        throw "Unsupported cleanup transaction schema version."
    }
    $stage = [string](Get-RequiredPropertyValue -Object $plan -Name "stage")
    if ($stage -notin $script:TransactionStages) {
        throw "Unsupported cleanup transaction stage '$stage'."
    }
    $storedFingerprint = [string](Get-RequiredPropertyValue -Object $plan -Name "planFingerprint")
    if ($storedFingerprint -cne (Get-CleanupFingerprint -Plan $plan)) {
        throw "Cleanup transaction fingerprint does not match its persisted identity and asset sets."
    }
    if ($storedFingerprint -cne (Get-CleanupFingerprint -Plan $ExpectedPlan)) {
        throw "Cleanup transaction does not match the current cleanup plan."
    }
    $storedStateFingerprint = [string](
        Get-RequiredPropertyValue -Object $plan -Name "stateFingerprint"
    )
    if ($storedStateFingerprint -cne (Get-CleanupStateFingerprint -Plan $plan)) {
        throw "Cleanup transaction stage or recorded results were modified."
    }
    $plan
}

function Assert-PreflightStillMatch {
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][object]$Operations
    )

    $consolidationDecision = Get-OptionalPropertyValue -Object $Plan -Name "consolidationDecision"
    if ($null -ne $consolidationDecision) {
        $liveMembers = @(
            Invoke-CleanupOperation `
                -Operations $Operations `
                -Name "ReadConsolidationMembers" `
                -Arguments @($consolidationDecision)
        )
        if (($liveMembers | ConvertTo-Json -Depth 30 -Compress) -cne
            (@($consolidationDecision.members) | ConvertTo-Json -Depth 30 -Compress)) {
            throw "Consolidation source evidence drifted before its atomic write."
        }
        return
    }
    $liveState = Invoke-CleanupOperation -Operations $Operations -Name "ReadLiveState" -Arguments @($Plan)
    $expectedValue = [ordered]@{
        retain = $Plan.retain
        remove = $Plan.remove
    }
    if ($null -ne (Get-OptionalPropertyValue -Object $Plan -Name "removals")) {
        $expectedValue.removals = @($Plan.removals)
    }
    $expected = [pscustomobject]$expectedValue
    $liveJson = $liveState | ConvertTo-Json -Depth 30 -Compress
    $expectedJson = $expected | ConvertTo-Json -Depth 30 -Compress
    if ($liveJson -cne $expectedJson) {
        throw "Cleanup preflight evidence drifted before the first destructive operation."
    }
    $validationValue = [ordered]@{}
    foreach ($property in $expected.PSObject.Properties) {
        $validationValue[$property.Name] = $property.Value
    }
    if ($null -ne (Get-OptionalPropertyValue -Object $Plan -Name "consolidationDecision")) {
        $validationValue.consolidationDecision = $Plan.consolidationDecision
    }
    Assert-DuplicateCleanupCandidate -Candidate ([pscustomobject]$validationValue) -Scope $Plan.scope
}

function Get-DeletedAction {
    param([Parameter(Mandatory = $true)][object]$Plan)

    $removalsProperty = Get-OptionalPropertyValue -Object $Plan -Name "removals"
    $removals = if ($null -ne $removalsProperty) { @($removalsProperty) } else { @($Plan.remove) }
    [pscustomobject][ordered]@{
        category = "deleted"
        kind = "strict_duplicate_cleanup"
        target = [pscustomobject][ordered]@{
            parentItemKey = [string]$Plan.retain.parent.key
            attachmentKey = [string]$Plan.retain.attachment.key
            path = [string]$Plan.retain.local.path
        }
        before = if ($null -ne $removalsProperty -and $removals.Count -gt 1) {
            [pscustomobject][ordered]@{ removedMembers = $removals }
        }
        else {
            [pscustomobject][ordered]@{
                parent = $removals[0].parent
                attachment = $removals[0].attachment
                storage = $removals[0].storage
                cache = $removals[0].cache
                local = $removals[0].local
            }
        }
        after = $null
        evidence = @(
            "transactionId:$($Plan.transactionId)"
            foreach ($property in $Plan.identity.PSObject.Properties) {
                "$($property.Name):$($property.Value)"
            }
        )
    }
}

function Get-ExpectedAssetEvidence {
    param([Parameter(Mandatory = $true)][object]$Plan)

    $removeKinds = switch ([string]$Plan.stage) {
        "storage_removed" { @("cache", "local") }
        "local_removed" { @("cache") }
        "cache_removed" { @() }
        "completed" { @() }
        default { @("storage", "cache", "local") }
    }
    $removalsProperty = Get-OptionalPropertyValue -Object $Plan -Name "removals"
    $isGroupPlan = $null -ne $removalsProperty
    $removals = if ($isGroupPlan) { @($removalsProperty) } else { @($Plan.remove) }
    @(
        foreach ($kind in @("storage", "cache", "local")) {
            [pscustomobject][ordered]@{
                side = "retain"
                kind = $kind
                value = $Plan.retain.$kind
            }
        }
        foreach ($redundant in $removals) {
            foreach ($kind in $removeKinds) {
                [pscustomobject][ordered]@{
                    side = if ($isGroupPlan) { "remove:$($redundant.parent.key)" } else { "remove" }
                    kind = $kind
                    value = $redundant.$kind
                }
            }
        }
    )
}

function Assert-CleanupSafety {
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][object]$Operations,
        [AllowNull()][string]$AllowedMissingRemoveKind
    )

    if ([string]$Plan.planFingerprint -cne (Get-CleanupFingerprint -Plan $Plan)) {
        throw "Cleanup transaction fingerprint no longer matches its fixed asset sets."
    }
    if ([string]$Plan.stateFingerprint -cne (Get-CleanupStateFingerprint -Plan $Plan)) {
        throw "Cleanup transaction stage proof no longer matches its persisted state."
    }
    $candidateValue = [ordered]@{ retain = $Plan.retain; remove = $Plan.remove }
    if ($null -ne (Get-OptionalPropertyValue -Object $Plan -Name "removals")) {
        $candidateValue.removals = @($Plan.removals)
        $candidateValue.consolidationDecision = $Plan.consolidationDecision
    }
    Assert-DuplicateCleanupCandidate `
        -Candidate ([pscustomobject]$candidateValue) `
        -Scope $Plan.scope
    $expected = @(Get-ExpectedAssetEvidence -Plan $Plan)
    $actual = @(
        Invoke-CleanupOperation `
            -Operations $Operations `
            -Name "ReadAssetEvidence" `
            -Arguments @($Plan, @($expected))
    )
    $expectedJson = $expected | ConvertTo-Json -Depth 30 -Compress
    $actualJson = $actual | ConvertTo-Json -Depth 30 -Compress
    if ($actualJson -ceq $expectedJson) {
        return $true
    }
    if (-not [string]::IsNullOrWhiteSpace($AllowedMissingRemoveKind)) {
        $expectedAfterRemoval = @(
            $expected | Where-Object {
                -not (
                    ([string]$_.side -ceq "remove" -or [string]$_.side -clike "remove:*") -and
                    [string]$_.kind -ceq $AllowedMissingRemoveKind
                )
            }
        )
        $expectedAfterRemovalJson = $expectedAfterRemoval |
            ConvertTo-Json -Depth 30 -Compress
        if ($actualJson -ceq $expectedAfterRemovalJson) {
            return $false
        }
    }
    throw "Cleanup asset hash, provenance, path, or retained-set evidence drifted."
}

function Test-CleanupStringSubset {
    param(
        [AllowNull()][object[]]$Subset,
        [AllowNull()][object[]]$Expected
    )

    $expectedValues = @(Get-SortedUniqueString -Value $Expected)
    @(
        Get-SortedUniqueString -Value $Subset |
            Where-Object { $_ -cnotin $expectedValues }
    ).Count -eq 0
}

function Invoke-PlannedCleanupStage {
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][string]$TransactionPath,
        [Parameter(Mandatory = $true)][object]$Operations
    )

    $null = Assert-CleanupSafety -Plan $Plan -Operations $Operations
    Assert-PreflightStillMatch -Plan $Plan -Operations $Operations
    Set-CleanupStage -Plan $Plan -Stage "preflighted" -TransactionPath $TransactionPath
}

function Invoke-PreflightedCleanupStage {
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][string]$TransactionPath,
        [Parameter(Mandatory = $true)][object]$Operations
    )

    $consolidationDecision = Get-OptionalPropertyValue -Object $Plan -Name "consolidationDecision"
    if ($null -eq $consolidationDecision) {
        Invoke-ConsolidatedCleanupStage `
            -Plan $Plan `
            -TransactionPath $TransactionPath `
            -Operations $Operations
        return
    }
    $result = Invoke-CleanupOperation `
        -Operations $Operations `
        -Name "ApplyConsolidation" `
        -Arguments @($consolidationDecision)
    $status = [string](Get-RequiredPropertyValue -Object $result -Name "status")
    if ($status -notin @("written", "already_applied")) {
        throw "Duplicate consolidation did not produce verified expected state: $status."
    }
    Set-CleanupStage -Plan $Plan -Stage "consolidated" -TransactionPath $TransactionPath
}

function Invoke-ConsolidatedCleanupStage {
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][string]$TransactionPath,
        [Parameter(Mandatory = $true)][object]$Operations
    )

    $null = Assert-CleanupSafety -Plan $Plan -Operations $Operations
    $trashKeys = @(Invoke-CleanupOperation -Operations $Operations -Name "GetTrashKeys")
    $liveKeys = @(
        Invoke-CleanupOperation `
            -Operations $Operations `
            -Name "GetLiveZoteroKeys" `
            -Arguments @(,@($Plan.deleteKeys))
    )
    if (-not (Test-CleanupStringSubset -Subset $trashKeys -Expected $Plan.deleteKeys) -or
        -not (Test-CleanupStringSubset -Subset $liveKeys -Expected $Plan.deleteKeys) -or
        @($trashKeys | Where-Object { $_ -cin $liveKeys }).Count -gt 0 -or
        -not (Test-ExactStringSet `
            -Actual (@($trashKeys) + @($liveKeys)) `
            -Expected $Plan.deleteKeys)) {
        throw "Live Zotero items and Trash are not the exact partition of the expected delete set."
    }
    if ($liveKeys.Count -gt 0) {
        Invoke-CleanupOperation `
            -Operations $Operations `
            -Name "TrashZotero" `
            -Arguments @(,@($liveKeys))
    }
    $verifiedTrash = @(Invoke-CleanupOperation -Operations $Operations -Name "GetTrashKeys")
    if (-not (Test-ExactStringSet -Actual $verifiedTrash -Expected $Plan.deleteKeys)) {
        throw "Zotero Trash is not the exact expected delete set."
    }
    Set-CleanupStage -Plan $Plan -Stage "trashed" -TransactionPath $TransactionPath
}

function Invoke-TrashedCleanupStage {
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][string]$TransactionPath,
        [Parameter(Mandatory = $true)][object]$Operations
    )

    $null = Assert-CleanupSafety -Plan $Plan -Operations $Operations
    $trashKeys = @(Invoke-CleanupOperation -Operations $Operations -Name "GetTrashKeys")
    if (-not (Test-ExactStringSet -Actual $trashKeys -Expected $Plan.deleteKeys)) {
        throw "Zotero Trash is not the exact expected delete set."
    }
    Set-CleanupStage -Plan $Plan -Stage "trash_verified" -TransactionPath $TransactionPath
}

function Invoke-TrashVerifiedCleanupStage {
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][string]$TransactionPath,
        [Parameter(Mandatory = $true)][object]$Operations
    )

    $null = Assert-CleanupSafety -Plan $Plan -Operations $Operations
    $existingKeys = @(
        Invoke-CleanupOperation `
            -Operations $Operations `
            -Name "GetExistingZoteroKeys" `
            -Arguments @(,@($Plan.deleteKeys))
    )
    if ($existingKeys.Count -gt 0) {
        if (-not (Test-ExactStringSet -Actual $existingKeys -Expected $Plan.deleteKeys)) {
            throw "The Zotero delete set drifted before permanent purge."
        }
        $trashKeys = @(Invoke-CleanupOperation -Operations $Operations -Name "GetTrashKeys")
        if (-not (Test-ExactStringSet -Actual $trashKeys -Expected $Plan.deleteKeys)) {
            throw "Zotero Trash changed before permanent purge."
        }
        Invoke-CleanupOperation `
            -Operations $Operations `
            -Name "PurgeZotero" `
            -Arguments @(,@($Plan.deleteKeys))
    }
    else {
        $trashKeys = @(Invoke-CleanupOperation -Operations $Operations -Name "GetTrashKeys")
        if ($trashKeys.Count -gt 0) {
            throw "Unexpected Zotero Trash content exists after the expected purge."
        }
    }
    $remainingKeys = @(
        Invoke-CleanupOperation `
            -Operations $Operations `
            -Name "GetExistingZoteroKeys" `
            -Arguments @(,@($Plan.deleteKeys))
    )
    if ($remainingKeys.Count -gt 0) {
        throw "Permanent Zotero purge did not remove the expected keys."
    }
    Set-CleanupStage -Plan $Plan -Stage "zotero_purged" -TransactionPath $TransactionPath
}

function Invoke-CleanupAssetRemovalStage {
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][string]$TransactionPath,
        [Parameter(Mandatory = $true)][object]$Operations,
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Operation,
        [Parameter(Mandatory = $true)][string]$NextStage
    )

    $assetExists = Assert-CleanupSafety `
        -Plan $Plan `
        -Operations $Operations `
        -AllowedMissingRemoveKind $Kind
    $removalsProperty = Get-OptionalPropertyValue -Object $Plan -Name "removals"
    $removals = if ($null -ne $removalsProperty) { @($removalsProperty) } else { @($Plan.remove) }
    $paths = @($removals | ForEach-Object { [string]$_.$Kind.path })
    if (-not $assetExists) {
        Set-CleanupStage -Plan $Plan -Stage $NextStage -TransactionPath $TransactionPath
        return
    }
    $existingPaths = @(
        Invoke-CleanupOperation `
            -Operations $Operations `
            -Name "GetExistingPaths" `
            -Arguments @($Kind, @($paths))
    )
    if ($existingPaths.Count -gt 0) {
        if (-not (Test-ExactStringSet -Actual $existingPaths -Expected $paths)) {
            throw "The $Kind delete set drifted."
        }
        Invoke-CleanupOperation `
            -Operations $Operations `
            -Name $Operation `
            -Arguments @(,@($paths))
    }
    $remainingPaths = @(
        Invoke-CleanupOperation `
            -Operations $Operations `
            -Name "GetExistingPaths" `
            -Arguments @($Kind, @($paths))
    )
    if ($remainingPaths.Count -gt 0) {
        throw "The $Kind delete operation did not remove the expected paths."
    }
    Set-CleanupStage -Plan $Plan -Stage $NextStage -TransactionPath $TransactionPath
}

function Invoke-ResumableCleanupTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$CleanupPlan,
        [Parameter(Mandatory = $true)][string]$TransactionPath,
        [Parameter(Mandatory = $true)][object]$Operations
    )

    $plan = if (Test-Path -LiteralPath $TransactionPath -PathType Leaf) {
        Read-CleanupPlan -TransactionPath $TransactionPath -ExpectedPlan $CleanupPlan
    }
    else {
        $CleanupPlan
    }
    $wasCompleted = [string]$plan.stage -eq "completed"
    if ($wasCompleted) {
        return [pscustomobject][ordered]@{
            completed = $true
            changed = $false
            action = $null
            plan = $plan
        }
    }
    if (-not (Test-Path -LiteralPath $TransactionPath -PathType Leaf)) {
        Write-CleanupPlan -Plan $plan -TransactionPath $TransactionPath
    }

    while ([string]$plan.stage -ne "completed") {
        switch ([string]$plan.stage) {
            "planned" {
                Invoke-PlannedCleanupStage -Plan $plan -TransactionPath $TransactionPath -Operations $Operations
            }
            "preflighted" {
                Invoke-PreflightedCleanupStage -Plan $plan -TransactionPath $TransactionPath -Operations $Operations
            }
            "consolidated" {
                Invoke-ConsolidatedCleanupStage -Plan $plan -TransactionPath $TransactionPath -Operations $Operations
            }
            "trashed" {
                Invoke-TrashedCleanupStage -Plan $plan -TransactionPath $TransactionPath -Operations $Operations
            }
            "trash_verified" {
                Invoke-TrashVerifiedCleanupStage -Plan $plan -TransactionPath $TransactionPath -Operations $Operations
            }
            "zotero_purged" {
                Invoke-CleanupAssetRemovalStage -Plan $plan -TransactionPath $TransactionPath `
                    -Operations $Operations -Kind "storage" -Operation "RemoveStorage" -NextStage "storage_removed"
            }
            "storage_removed" {
                Invoke-CleanupAssetRemovalStage -Plan $plan -TransactionPath $TransactionPath `
                    -Operations $Operations -Kind "local" -Operation "RemoveLocal" -NextStage "local_removed"
            }
            "local_removed" {
                Invoke-CleanupAssetRemovalStage -Plan $plan -TransactionPath $TransactionPath `
                    -Operations $Operations -Kind "cache" -Operation "RemoveCache" -NextStage "cache_removed"
            }
            "cache_removed" {
                $null = Assert-CleanupSafety -Plan $plan -Operations $Operations
                Set-CleanupStage -Plan $plan -Stage "completed" -TransactionPath $TransactionPath
            }
            default { throw "Unsupported cleanup transaction stage '$($plan.stage)'." }
        }
    }
    [pscustomobject][ordered]@{
        completed = [string]$plan.stage -eq "completed"
        changed = -not $wasCompleted
        action = if ([string]$plan.stage -eq "completed") { Get-DeletedAction -Plan $plan } else { $null }
        plan = $plan
    }
}

function New-CleanupTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Constructs an in-memory target contract and does not change external state."
    )]
    param([AllowNull()][object]$Candidate)

    if ($null -eq $Candidate) {
        return [pscustomobject][ordered]@{
            parentItemKey = $null
            attachmentKey = $null
            path = $null
        }
    }
    [pscustomobject][ordered]@{
        parentItemKey = [string]$Candidate.retain.parent.key
        attachmentKey = [string]$Candidate.retain.attachment.key
        path = [string]$Candidate.retain.local.path
    }
}

function Get-ConsolidationModifiedAction {
    param([Parameter(Mandatory = $true)][object]$Plan)

    $decision = Get-RequiredPropertyValue -Object $Plan -Name "consolidationDecision"
    [pscustomobject][ordered]@{
        category = "modified"
        kind = "duplicate_user_state_consolidated"
        target = [pscustomobject][ordered]@{
            parentItemKey = [string]$decision.retainedParent.key
            attachmentKey = [string]$decision.retainedAttachment.key
            path = [string]$Plan.retain.local.path
        }
        before = [pscustomobject][ordered]@{
            members = @($decision.members)
        }
        after = [pscustomobject][ordered]@{
            parentItemKey = [string]$decision.retainedParent.key
            attachmentKey = [string]$decision.retainedAttachment.key
            mergedState = $decision.mergedState
        }
        evidence = @(
            "transactionId:$($Plan.transactionId)",
            "identity:$($decision.identity.kind)"
        )
    }
}

function Invoke-CleanupCandidateTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Scope,
        [Parameter(Mandatory = $true)][object]$Candidate,
        [Parameter(Mandatory = $true)][object]$Operations
    )

    $target = New-CleanupTarget -Candidate $Candidate
    $plan = ConvertTo-CleanupPlan -Candidate $Candidate -Scope $Scope
    $transactionRoot = Join-Path $Scope.zoteroDataDir "zotero-paper-updater-transactions"
    $memberKeys = @(
        @([string]$plan.retain.parent.key) +
        @(
            if ($null -ne (Get-OptionalPropertyValue -Object $plan -Name "removals")) {
                @($plan.removals.parent.key)
            }
            else {
                @([string]$plan.remove.parent.key)
            }
        ) | Sort-Object
    )
    $transactionName = if (
        $null -ne (Get-OptionalPropertyValue -Object $plan -Name "consolidationDecision")
    ) {
        "cleanup-v1-$($memberKeys -join '-')-$($plan.planFingerprint.Substring(0, 12)).json"
    }
    else {
        "cleanup-v1-$($memberKeys -join '-').json"
    }
    $transactionPath = Join-Path $transactionRoot $transactionName
    $transaction = Invoke-ResumableCleanupTransaction `
        -CleanupPlan $plan `
        -TransactionPath $transactionPath `
        -Operations $Operations
    $actions = [Collections.Generic.List[object]]::new()
    if ($transaction.changed -and
        $null -ne (Get-OptionalPropertyValue -Object $plan -Name "consolidationDecision") -and
        [bool](Get-RequiredPropertyValue -Object $plan.consolidationDecision -Name "requiresWrite")) {
        $actions.Add((Get-ConsolidationModifiedAction -Plan $plan))
    }
    if ($null -ne $transaction.action) { $actions.Add($transaction.action) }
    [pscustomobject][ordered]@{
        target = $target
        status = "succeeded"
        actions = @($actions)
        issues = @()
    }
}

function Invoke-MinimalDuplicateCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Scope,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Targets,
        [Parameter(Mandatory = $true)][object]$Operations
    )

    $candidate = $null
    $target = if ($Targets.Count -gt 0) { $Targets[0] } else { New-CleanupTarget -Candidate $null }
    try {
        $candidates = @(
            Invoke-CleanupOperation `
                -Operations $Operations `
                -Name "FindCandidates" `
                -Arguments @($Scope, @($Targets))
        )
        if ($candidates.Count -eq 0) {
            return [pscustomobject][ordered]@{
                target = New-CleanupTarget -Candidate $null
                status = "succeeded"
                actions = @()
                issues = @()
            }
        }
        if ($candidates.Count -ne 1) {
            throw "Issue #13 supports exactly one minimal duplicate group per cleanup run."
        }
        $candidate = $candidates[0]
        $target = New-CleanupTarget -Candidate $candidate
        Invoke-CleanupCandidateTransaction `
            -Scope $Scope `
            -Candidate $candidate `
            -Operations $Operations
    }
    catch {
        $issueCode = [string]$_.Exception.Data["ZpuIssueCode"]
        if ([string]::IsNullOrWhiteSpace($issueCode)) {
            $issueCode = "duplicate_cleanup_blocked"
        }
        [pscustomobject][ordered]@{
            target = $target
            status = "failed"
            actions = @()
            issues = @(
                [pscustomobject][ordered]@{
                    severity = "error"
                    code = $issueCode
                    target = $target
                    message = $_.Exception.Message
                    evidence = @($_.Exception.GetType().FullName)
                }
            )
        }
    }
}

Export-ModuleMember -Function `
    Invoke-MinimalDuplicateCleanup, `
    Invoke-ResumableCleanupTransaction, `
    Invoke-CleanupCandidateTransaction
