Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "ZoteroPaperUpdater.Common.psm1") -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "ZoteroPaperUpdater.DuplicateCleanup.psm1") -DisableNameChecking

$script:CleanupTransactionSchemaVersions = @(1, 2)

function New-CoordinatorIssue {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Constructs an in-memory issue contract without changing external state."
    )]
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message,
        [AllowNull()][object]$Target,
        [AllowNull()][string]$TransactionPath
    )

    [pscustomobject][ordered]@{
        severity = "error"
        code = $Code
        target = $Target
        message = $Message
        evidence = @(
            if (-not [string]::IsNullOrWhiteSpace($TransactionPath)) {
                "transactionPath:$TransactionPath"
            }
        )
    }
}

function Get-CleanupLibraryMutexName {
    param(
        [Parameter(Mandatory = $true)][string]$ZoteroDataDir
    )

    $fullPath = [IO.Path]::GetFullPath($ZoteroDataDir)
    $root = [IO.Path]::GetPathRoot($fullPath)
    $canonical = $root
    $relative = $fullPath.Substring($root.Length)
    foreach ($segment in $relative.Split(
        @([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar),
        [StringSplitOptions]::RemoveEmptyEntries
    )) {
        $candidate = Join-Path $canonical $segment
        if (Test-Path -LiteralPath $candidate) {
            $item = Get-Item -LiteralPath $candidate -Force
            $target = if ($null -ne $item.LinkType) {
                $item.ResolveLinkTarget($true)
            }
            else {
                $null
            }
            $canonical = if ($null -ne $target) { $target.FullName } else { $item.FullName }
        }
        else {
            $canonical = $candidate
        }
    }
    $canonical = [IO.Path]::GetFullPath($canonical).
        TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar).
        ToUpperInvariant()
    $bytes = [Text.Encoding]::UTF8.GetBytes($canonical)
    $sha = $null
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        "Local\ZoteroPaperUpdater-" + [Convert]::ToHexString($sha.ComputeHash($bytes))
    }
    finally {
        if ($null -ne $sha) { $sha.Dispose() }
    }
}

function Get-CleanupTransactionFootprint {
    param([Parameter(Mandatory = $true)][object]$Plan)

    [pscustomobject][ordered]@{
        keys = @(
            @($Plan.deleteKeys) +
            @([string]$Plan.retain.parent.key, [string]$Plan.retain.attachment.key) |
                ForEach-Object { ([string]$_).ToUpperInvariant() } |
                Sort-Object -Unique
        )
        paths = @(
        foreach ($kind in @("storage", "cache", "local")) {
            [IO.Path]::GetFullPath([string]$Plan.retain.$kind.path)
        }
        $removals = if ($null -ne (Get-OptionalPropertyValue -Object $Plan -Name "removals")) {
            @($Plan.removals)
        }
        else {
            @($Plan.remove)
        }
        foreach ($member in $removals) {
            foreach ($kind in @("storage", "cache", "local")) {
                    [IO.Path]::GetFullPath([string]$member.$kind.path)
            }
        }
        )
    }
}

function Test-CoordinatorPathOverlap {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    $leftFull = [IO.Path]::GetFullPath($Left).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $rightFull = [IO.Path]::GetFullPath($Right).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $comparison = [StringComparison]::OrdinalIgnoreCase
    $leftFull.Equals($rightFull, $comparison) -or
        $leftFull.StartsWith($rightFull + [IO.Path]::DirectorySeparatorChar, $comparison) -or
        $rightFull.StartsWith($leftFull + [IO.Path]::DirectorySeparatorChar, $comparison)
}

function Read-PendingCleanupTransaction {
    param([Parameter(Mandatory = $true)][string]$TransactionRoot)

    if (-not (Test-Path -LiteralPath $TransactionRoot -PathType Container)) {
        return @()
    }
    $seenIds = @{}
    $pending = [Collections.Generic.List[object]]::new()
    $records = [Collections.Generic.List[object]]::new()
    @(
        foreach ($file in Get-ChildItem -LiteralPath $TransactionRoot -Filter "cleanup-v*-*.json" -File) {
            try {
                $plan = Get-Content -LiteralPath $file.FullName -Raw |
                    ConvertFrom-Json -Depth 30
                if ([int](Get-RequiredPropertyValue -Object $plan -Name "schemaVersion") -notin
                    $script:CleanupTransactionSchemaVersions) {
                    throw "Unsupported cleanup transaction schema."
                }
                $id = [string](Get-RequiredPropertyValue -Object $plan -Name "transactionId")
                $createdAtValue = Get-OptionalPropertyValue -Object $plan -Name "createdAt"
                $createdAt = [DateTimeOffset]::MinValue
                if ($null -ne $createdAtValue) {
                    $createdAt = [DateTimeOffset]::Parse(
                        [string]$createdAtValue,
                        [Globalization.CultureInfo]::InvariantCulture,
                        [Globalization.DateTimeStyles]::RoundtripKind
                    )
                    $isUtc = if ($createdAtValue -is [DateTime]) {
                        $createdAtValue.Kind -eq [DateTimeKind]::Utc
                    }
                    else {
                        ([string]$createdAtValue).EndsWith(
                            "Z",
                            [StringComparison]::OrdinalIgnoreCase
                        )
                    }
                    if (-not $isUtc) {
                        throw "Cleanup transaction createdAt must be UTC."
                    }
                }
                elseif ([int]$plan.schemaVersion -ge 2) {
                    throw "Cleanup transaction createdAt is required by schema v2."
                }
                if ($seenIds.ContainsKey($id)) {
                    throw "Cleanup transaction id '$id' is duplicated."
                }
                $seenIds[$id] = $file.FullName
                $validatedPlan = Read-CleanupPlan `
                    -TransactionPath $file.FullName `
                    -ExpectedPlan $plan
                $record = [pscustomobject][ordered]@{
                    path = $file.FullName
                    id = $id
                    createdAt = $createdAt
                    plan = $validatedPlan
                }
                if ([string]$validatedPlan.stage -ne "completed") {
                    $pending.Add($record)
                }
                $records.Add($record)
            }
            catch {
                $exception = [IO.InvalidDataException]::new(
                    "Invalid pending cleanup transaction '$($file.FullName)': $($_.Exception.Message)",
                    $_.Exception
                )
                $exception.Data["ZpuIssueCode"] = "cleanup_pending_invalid"
                throw $exception
            }
        }
    ) | Out-Null

    for ($leftIndex = 0; $leftIndex -lt $pending.Count; $leftIndex++) {
        $left = Get-CleanupTransactionFootprint -Plan $pending[$leftIndex].plan
        for ($rightIndex = $leftIndex + 1; $rightIndex -lt $pending.Count; $rightIndex++) {
            $right = Get-CleanupTransactionFootprint -Plan $pending[$rightIndex].plan
            if (@($left.keys | Where-Object { $_ -cin @($right.keys) }).Count -gt 0) {
                throw "Pending cleanup transactions overlap Zotero member keys."
            }
            foreach ($leftPath in $left.paths) {
                foreach ($rightPath in $right.paths) {
                    if (Test-CoordinatorPathOverlap -Left $leftPath -Right $rightPath) {
                        throw "Pending cleanup transactions overlap asset paths."
                    }
                }
            }
        }
    }

    @($records | Sort-Object createdAt, id)
}

function Invoke-CleanupRecoveryCoordinator {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Scope,
        [Parameter(Mandatory = $true)][object]$Operations,
        [int]$MutexTimeoutMilliseconds = 0,
        [AllowNull()][object]$FallbackTarget,
        [AllowNull()][scriptblock]$Continuation
    )

    $mutexName = Get-CleanupLibraryMutexName `
        -ZoteroDataDir ([string]$Scope.zoteroDataDir)
    $mutex = [Threading.Mutex]::new($false, $mutexName)
    $lockTaken = $false
    try {
        try {
            $lockTaken = $mutex.WaitOne($MutexTimeoutMilliseconds)
        }
        catch [Threading.AbandonedMutexException] {
            $lockTaken = $true
        }
        if (-not $lockTaken) {
            return [pscustomobject][ordered]@{
                target = $FallbackTarget
                status = "failed"
                actions = @()
                issues = @(
                    New-CoordinatorIssue `
                        -Code "cleanup_library_busy" `
                        -Message "Another cleanup coordinator owns this Zotero library." `
                        -Target $FallbackTarget
                )
                results = @()
            }
        }

        $transactionRoot = Join-Path $Scope.zoteroDataDir "zotero-paper-updater-transactions"
        try {
            $transactions = @(Read-PendingCleanupTransaction -TransactionRoot $transactionRoot)
        }
        catch {
            $code = [string]$_.Exception.Data["ZpuIssueCode"]
            if ([string]::IsNullOrWhiteSpace($code)) { $code = "cleanup_pending_invalid" }
            return [pscustomobject][ordered]@{
                target = $FallbackTarget
                status = "failed"
                actions = @()
                issues = @(
                    New-CoordinatorIssue `
                        -Code $code `
                        -Message $_.Exception.Message `
                        -Target $FallbackTarget
                )
                results = @()
            }
        }

        $actions = [Collections.Generic.List[object]]::new()
        $results = [Collections.Generic.List[object]]::new()
        foreach ($transaction in $transactions) {
            try {
                $result = Invoke-ResumableCleanupTransaction `
                    -CleanupPlan $transaction.plan `
                    -TransactionPath $transaction.path `
                    -Operations $Operations
                $results.Add($result)
                if ($null -ne $result.action) { $actions.Add($result.action) }
            }
            catch {
                $code = [string]$_.Exception.Data["ZpuIssueCode"]
                if ([string]::IsNullOrWhiteSpace($code)) {
                    $code = "cleanup_recovery_blocked"
                }
                $transactionTarget = [pscustomobject][ordered]@{
                    parentItemKey = [string]$transaction.plan.retain.parent.key
                    attachmentKey = [string]$transaction.plan.retain.attachment.key
                    path = [string]$transaction.plan.retain.local.path
                }
                return [pscustomobject][ordered]@{
                    target = $transactionTarget
                    status = if ($actions.Count -gt 0) { "partial" } else { "failed" }
                    actions = @($actions)
                    issues = @(
                        New-CoordinatorIssue `
                            -Code $code `
                            -Message $_.Exception.Message `
                            -Target $transactionTarget `
                            -TransactionPath $transaction.path
                    )
                    results = @($results)
                }
            }
        }
        $continuationResult = if ($null -ne $Continuation) {
            & $Continuation
        }
        else {
            [pscustomobject][ordered]@{
                target = $null
                status = "succeeded"
                actions = @()
                issues = @()
                results = @()
            }
        }
        $resultTarget = Get-OptionalPropertyValue -Object $continuationResult -Name "target"
        if ($null -eq $resultTarget -and $actions.Count -gt 0) {
            $resultTarget = Get-OptionalPropertyValue -Object $actions[0] -Name "target"
        }
        if ($null -eq $resultTarget -and @($continuationResult.issues).Count -gt 0) {
            $resultTarget = Get-OptionalPropertyValue `
                -Object @($continuationResult.issues)[0] `
                -Name "target"
        }
        if ($null -eq $resultTarget) { $resultTarget = $FallbackTarget }
        [pscustomobject][ordered]@{
            target = $resultTarget
            status = [string]$continuationResult.status
            actions = @($actions) + @($continuationResult.actions)
            issues = @($continuationResult.issues)
            results = @($results) + @($continuationResult.results)
        }
    }
    finally {
        try {
            if ($lockTaken) { $mutex.ReleaseMutex() }
        }
        finally {
            $mutex.Dispose()
        }
    }
}

Export-ModuleMember -Function `
    Get-CleanupLibraryMutexName, `
    Read-PendingCleanupTransaction, `
    Invoke-CleanupRecoveryCoordinator
