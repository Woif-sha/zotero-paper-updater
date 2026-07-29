Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "ZoteroPaperUpdater.Common.psm1") -DisableNameChecking

$script:TransactionSchemaVersion = 1
$script:TransactionStages = @(
    "planned",
    "preflighted",
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

function Get-NormalizedDoi {
    param([AllowNull()][string]$Doi)

    if ([string]::IsNullOrWhiteSpace($Doi)) {
        return $null
    }
    ($Doi.Trim() -replace "^(?i:https?://(?:dx\.)?doi\.org/)", "").ToLowerInvariant()
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

function Assert-MinimalDuplicateCandidate {
    param(
        [Parameter(Mandatory = $true)][object]$Candidate,
        [Parameter(Mandatory = $true)][object]$Scope
    )

    $retain = Get-RequiredPropertyValue -Object $Candidate -Name "retain"
    $remove = Get-RequiredPropertyValue -Object $Candidate -Name "remove"
    $retainParentKey = [string](Get-RequiredNestedValue -Object $retain -Path @("parent", "key"))
    $removeParentKey = [string](Get-RequiredNestedValue -Object $remove -Path @("parent", "key"))
    if ([string]::IsNullOrWhiteSpace($retainParentKey) -or
        [string]::IsNullOrWhiteSpace($removeParentKey) -or
        $retainParentKey -ceq $removeParentKey) {
        throw "A minimal duplicate candidate must contain exactly two distinct parent items."
    }

    $retainDoi = Get-NormalizedDoi ([string](Get-RequiredNestedValue -Object $retain -Path @("parent", "doi")))
    $removeDoi = Get-NormalizedDoi ([string](Get-RequiredNestedValue -Object $remove -Path @("parent", "doi")))
    if ([string]::IsNullOrWhiteSpace($retainDoi) -or $retainDoi -cne $removeDoi) {
        throw "Minimal duplicate cleanup requires the same canonical DOI on both parent items."
    }

    foreach ($side in @($retain, $remove)) {
        if (-not [bool](Get-RequiredNestedValue -Object $side -Path @("cache", "healthy"))) {
            throw "Minimal duplicate cleanup requires a healthy MinerU cache on both sides."
        }
    }
    $retainMarkdownHash = [string](Get-RequiredNestedValue -Object $retain -Path @("cache", "fullMdSha256"))
    $removeMarkdownHash = [string](Get-RequiredNestedValue -Object $remove -Path @("cache", "fullMdSha256"))
    if ([string]::IsNullOrWhiteSpace($retainMarkdownHash) -or
        $retainMarkdownHash -cne $removeMarkdownHash) {
        throw "Validated MinerU Markdown must confirm the same work."
    }
    if (-not [bool](Get-RequiredPropertyValue -Object $remove -Name "userStateEmpty")) {
        throw "The removed side contains user state that issue #13 cannot consolidate losslessly."
    }

    $pathRules = @(
        @("retain storage", (Get-RequiredNestedValue -Object $retain -Path @("storage", "path")), (Join-Path $Scope.zoteroDataDir "storage")),
        @("remove storage", (Get-RequiredNestedValue -Object $remove -Path @("storage", "path")), (Join-Path $Scope.zoteroDataDir "storage")),
        @("retain cache", (Get-RequiredNestedValue -Object $retain -Path @("cache", "path")), (Join-Path $Scope.zoteroDataDir "llm-for-zotero-mineru")),
        @("remove cache", (Get-RequiredNestedValue -Object $remove -Path @("cache", "path")), (Join-Path $Scope.zoteroDataDir "llm-for-zotero-mineru")),
        @("retain local", (Get-RequiredNestedValue -Object $retain -Path @("local", "path")), $Scope.paperRoot),
        @("remove local", (Get-RequiredNestedValue -Object $remove -Path @("local", "path")), $Scope.paperRoot)
    )
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

    [pscustomobject][ordered]@{
        schemaVersion = Get-RequiredPropertyValue -Object $Plan -Name "schemaVersion"
        scope = Get-RequiredPropertyValue -Object $Plan -Name "scope"
        identity = Get-RequiredPropertyValue -Object $Plan -Name "identity"
        retain = Get-RequiredPropertyValue -Object $Plan -Name "retain"
        remove = Get-RequiredPropertyValue -Object $Plan -Name "remove"
        deleteKeys = @(Get-RequiredPropertyValue -Object $Plan -Name "deleteKeys")
    }
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
    foreach ($name in @(
        "preflightedAt",
        "trashedAt",
        "trashVerifiedAt",
        "zoteroPurgedAt",
        "storageRemovedAt",
        "localRemovedAt",
        "cacheRemovedAt",
        "completedAt"
    )) {
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

    Assert-MinimalDuplicateCandidate -Candidate $Candidate -Scope $Scope
    $retain = Get-RequiredPropertyValue -Object $Candidate -Name "retain"
    $remove = Get-RequiredPropertyValue -Object $Candidate -Name "remove"
    $plan = [pscustomobject][ordered]@{
        schemaVersion = $script:TransactionSchemaVersion
        transactionId = [guid]::NewGuid().ToString()
        stage = "planned"
        scope = [pscustomobject][ordered]@{
            paperRoot = [IO.Path]::GetFullPath([string]$Scope.paperRoot)
            zoteroDataDir = [IO.Path]::GetFullPath([string]$Scope.zoteroDataDir)
        }
        identity = [pscustomobject][ordered]@{
            doi = Get-NormalizedDoi ([string](Get-RequiredNestedValue -Object $retain -Path @("parent", "doi")))
            fullMdSha256 = [string](Get-RequiredNestedValue -Object $retain -Path @("cache", "fullMdSha256"))
        }
        retain = $retain
        remove = $remove
        deleteKeys = @(
            [string](Get-RequiredNestedValue -Object $remove -Path @("attachment", "key")),
            [string](Get-RequiredNestedValue -Object $remove -Path @("parent", "key"))
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

    $liveState = Invoke-CleanupOperation -Operations $Operations -Name "ReadLiveState" -Arguments @($Plan)
    $expected = [pscustomobject][ordered]@{
        retain = $Plan.retain
        remove = $Plan.remove
    }
    $liveJson = $liveState | ConvertTo-Json -Depth 30 -Compress
    $expectedJson = $expected | ConvertTo-Json -Depth 30 -Compress
    if ($liveJson -cne $expectedJson) {
        throw "Cleanup preflight evidence drifted before the first destructive operation."
    }
    Assert-MinimalDuplicateCandidate -Candidate $expected -Scope $Plan.scope
}

function Get-DeletedAction {
    param([Parameter(Mandatory = $true)][object]$Plan)

    [pscustomobject][ordered]@{
        category = "deleted"
        kind = "strict_duplicate_cleanup"
        target = [pscustomobject][ordered]@{
            parentItemKey = [string]$Plan.retain.parent.key
            attachmentKey = [string]$Plan.retain.attachment.key
            path = [string]$Plan.retain.local.path
        }
        before = [pscustomobject][ordered]@{
            parent = $Plan.remove.parent
            attachment = $Plan.remove.attachment
            storage = $Plan.remove.storage
            cache = $Plan.remove.cache
            local = $Plan.remove.local
        }
        after = $null
        evidence = @(
            "transactionId:$($Plan.transactionId)",
            "doi:$($Plan.identity.doi)",
            "fullMdSha256:$($Plan.identity.fullMdSha256)"
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
    @(
        foreach ($sideName in @("retain", "remove")) {
            $kinds = if ($sideName -eq "retain") {
                @("storage", "cache", "local")
            }
            else {
                $removeKinds
            }
            foreach ($kind in $kinds) {
                [pscustomobject][ordered]@{
                    side = $sideName
                    kind = $kind
                    value = $Plan.$sideName.$kind
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
    Assert-MinimalDuplicateCandidate `
        -Candidate ([pscustomobject]@{ retain = $Plan.retain; remove = $Plan.remove }) `
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
                    [string]$_.side -ceq "remove" -and
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
    $paths = @([string]$Plan.remove.$Kind.path)
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
        $plan = ConvertTo-CleanupPlan -Candidate $candidate -Scope $Scope
        $transactionRoot = Join-Path $Scope.zoteroDataDir "zotero-paper-updater-transactions"
        $transactionName = "cleanup-v1-$($plan.retain.parent.key)-$($plan.remove.parent.key).json"
        $transactionPath = Join-Path $transactionRoot $transactionName
        $transaction = Invoke-ResumableCleanupTransaction `
            -CleanupPlan $plan `
            -TransactionPath $transactionPath `
            -Operations $Operations
        [pscustomobject][ordered]@{
            target = $target
            status = "succeeded"
            actions = @(if ($null -ne $transaction.action) { $transaction.action })
            issues = @()
        }
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
    Invoke-ResumableCleanupTransaction
