[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$cleanupPath = Join-Path $repoRoot "scripts\ZoteroPaperUpdater.DuplicateCleanup.psm1"
$coordinatorPath = Join-Path $repoRoot "scripts\ZoteroPaperUpdater.CleanupCoordinator.psm1"
Import-Module $cleanupPath -Force -DisableNameChecking
Import-Module $coordinatorPath -Force -DisableNameChecking

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) (
    "zpu-cleanup-coordinator-" + [guid]::NewGuid().ToString("N")
)
$passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:passed++
}

function New-CoordinatorCandidate {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Creates only isolated per-test fixture files under the temporary root."
    )]
    param(
        [string]$Root,
        [string]$RetainKey,
        [string]$RemoveKey,
        [string]$RetainAttachment,
        [string]$RemoveAttachment
    )

    $dataRoot = Join-Path $Root "ZoteroData"
    $paperRoot = Join-Path $Root "papers"
    [IO.Directory]::CreateDirectory((Join-Path $dataRoot "storage")) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $dataRoot "llm-for-zotero-mineru")) | Out-Null
    [IO.Directory]::CreateDirectory($paperRoot) | Out-Null
    $side = {
        param($ParentKey, $AttachmentKey)
        [pscustomobject][ordered]@{
            parent = [pscustomobject][ordered]@{
                key = $ParentKey
                version = 1
                doi = "10.1000/coordinator"
                tags = @()
                collections = @()
                relations = [pscustomobject]@{}
                childKeys = @($AttachmentKey)
                notes = @()
                unknownChildren = @()
                inboundRelations = @()
            }
            attachment = [pscustomobject][ordered]@{
                key = $AttachmentKey
                version = 1
                relations = [pscustomobject]@{}
                tags = @()
                hasAnnotations = $false
                isFinal = $true
            }
            storage = [pscustomobject][ordered]@{
                path = Join-Path $dataRoot "storage\$AttachmentKey"
                pdfPath = Join-Path $dataRoot "storage\$AttachmentKey\$AttachmentKey.pdf"
                sha256 = "HASH-$AttachmentKey"
            }
            cache = [pscustomobject][ordered]@{
                path = Join-Path $dataRoot "llm-for-zotero-mineru\$AttachmentKey"
                healthy = $true
                fullMdSha256 = "MD-SAME"
                attachmentKey = $AttachmentKey
                parentItemKey = $ParentKey
            }
            local = [pscustomobject][ordered]@{
                path = Join-Path $paperRoot "$AttachmentKey.pdf"
                sha256 = "HASH-$AttachmentKey"
            }
            userStateEmpty = $true
        }
    }
    [pscustomobject][ordered]@{
        scope = [pscustomobject][ordered]@{
            paperRoot = $paperRoot
            zoteroDataDir = $dataRoot
        }
        candidate = [pscustomobject][ordered]@{
            retain = & $side $RetainKey $RetainAttachment
            remove = & $side $RemoveKey $RemoveAttachment
        }
    }
}

function New-CoordinatorOperationTable {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Constructs an in-memory fake boundary operation table."
    )]
    param([object[]]$Plans)

    $state = [pscustomobject]@{
        liveKeys = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
        trashKeys = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
        paths = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
        calls = [Collections.Generic.List[string]]::new()
    }
    foreach ($plan in $Plans) {
        foreach ($key in @($plan.deleteKeys)) { $null = $state.liveKeys.Add([string]$key) }
        foreach ($member in @($plan.remove)) {
            foreach ($kind in @("storage", "cache", "local")) {
                $null = $state.paths.Add([string]$member.$kind.path)
            }
        }
    }
    $operations = [pscustomobject]@{
        ReadLiveState = {
            param($Plan)
            [pscustomobject][ordered]@{ retain = $Plan.retain; remove = $Plan.remove }
        }.GetNewClosure()
        GetTrashKeys = { @($state.trashKeys) }.GetNewClosure()
        GetLiveZoteroKeys = {
            param($Keys)
            @($Keys | Where-Object { $state.liveKeys.Contains([string]$_) })
        }.GetNewClosure()
        GetExistingZoteroKeys = {
            param($Keys)
            @(
                $Keys | Where-Object {
                    $state.liveKeys.Contains([string]$_) -or
                    $state.trashKeys.Contains([string]$_)
                }
            )
        }.GetNewClosure()
        TrashZotero = {
            param($Keys)
            $state.calls.Add("trash:$($Keys[0])")
            foreach ($key in $Keys) {
                $null = $state.liveKeys.Remove([string]$key)
                $null = $state.trashKeys.Add([string]$key)
            }
        }.GetNewClosure()
        PurgeZotero = {
            param($Keys)
            $state.calls.Add("purge:$($Keys[0])")
            foreach ($key in $Keys) { $null = $state.trashKeys.Remove([string]$key) }
        }.GetNewClosure()
        ReadAssetEvidence = {
            param($Plan, $Expected)
            $null = $Plan
            @($Expected | Where-Object {
                [string]$_.side -eq "retain" -or
                $state.paths.Contains([string]$_.value.path)
            })
        }.GetNewClosure()
        GetExistingPaths = {
            param($Kind, $Paths)
            $null = $Kind
            @($Paths | Where-Object { $state.paths.Contains([string]$_) })
        }.GetNewClosure()
        RemoveStorage = {
            param($Paths)
            $state.calls.Add("storage:$($Paths[0])")
            foreach ($path in $Paths) { $null = $state.paths.Remove([string]$path) }
        }.GetNewClosure()
        RemoveLocal = {
            param($Paths)
            $state.calls.Add("local:$($Paths[0])")
            foreach ($path in $Paths) { $null = $state.paths.Remove([string]$path) }
        }.GetNewClosure()
        RemoveCache = {
            param($Paths)
            $state.calls.Add("cache:$($Paths[0])")
            foreach ($path in $Paths) { $null = $state.paths.Remove([string]$path) }
        }.GetNewClosure()
    }
    [pscustomobject]@{ state = $state; operations = $operations }
}

function Write-CoordinatorPlan {
    param([object]$Plan, [string]$Path)
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [IO.File]::WriteAllText(
        $Path,
        ($Plan | ConvertTo-Json -Depth 30),
        [Text.UTF8Encoding]::new($false)
    )
}

try {
    $firstFixture = New-CoordinatorCandidate `
        -Root (Join-Path $tempRoot "fifo") `
        -RetainKey "KEEP1111" `
        -RemoveKey "DROP1111" `
        -RetainAttachment "ATKEEP11" `
        -RemoveAttachment "ATDROP11"
    $secondFixture = New-CoordinatorCandidate `
        -Root (Join-Path $tempRoot "fifo") `
        -RetainKey "KEEP2222" `
        -RemoveKey "DROP2222" `
        -RetainAttachment "ATKEEP22" `
        -RemoveAttachment "ATDROP22"
    $firstPlan = ConvertTo-CleanupPlan `
        -Candidate $firstFixture.candidate `
        -Scope $firstFixture.scope
    $secondPlan = ConvertTo-CleanupPlan `
        -Candidate $secondFixture.candidate `
        -Scope $secondFixture.scope
    $firstPlan.createdAt = "2026-07-30T00:00:00.0000000Z"
    $firstPlan.stateFingerprint = Get-CleanupStateFingerprint -Plan $firstPlan
    $secondPlan.createdAt = "2026-07-30T00:00:01.0000000Z"
    $secondPlan.stateFingerprint = Get-CleanupStateFingerprint -Plan $secondPlan
    $transactionRoot = Join-Path $firstFixture.scope.zoteroDataDir `
        "zotero-paper-updater-transactions"
    Write-CoordinatorPlan -Plan $secondPlan -Path (Join-Path $transactionRoot "cleanup-v1-b.json")
    Write-CoordinatorPlan -Plan $firstPlan -Path (Join-Path $transactionRoot "cleanup-v1-a.json")
    $runtime = New-CoordinatorOperationTable -Plans @($firstPlan, $secondPlan)
    $fallback = [pscustomobject]@{
        parentItemKey = "KEEP1111"
        attachmentKey = "ATKEEP11"
        path = $firstPlan.retain.local.path
    }
    $fifoResult = Invoke-CleanupRecoveryCoordinator `
        -Scope $firstFixture.scope `
        -Operations $runtime.operations `
        -FallbackTarget $fallback
    Assert-True ($fifoResult.status -eq "succeeded") "two pending transactions should complete: $($fifoResult | ConvertTo-Json -Depth 10 -Compress)"
    Assert-True ($fifoResult.actions.Count -eq 2) "each first completion should emit one deletion"
    Assert-True (
        [string]$runtime.state.calls[0] -match "ATDROP11"
    ) "FIFO should execute the older transaction first: $($runtime.state.calls -join ',')"
    $secondStart = @(
        0..($runtime.state.calls.Count - 1) |
            Where-Object { [string]$runtime.state.calls[$_] -match "ATDROP22" }
    )[0]
    Assert-True ($secondStart -ge 5) "the second transaction must start after the first completes"

    $noop = Invoke-CleanupRecoveryCoordinator `
        -Scope $firstFixture.scope `
        -Operations $runtime.operations `
        -FallbackTarget $fallback
    Assert-True ($noop.status -eq "succeeded") "completed transactions should verify as no-op"
    Assert-True ($noop.actions.Count -eq 0) "completed no-op must not repeat deleted actions"

    $null = $runtime.state.liveKeys.Add("DROP1111")
    $orphan = Invoke-CleanupRecoveryCoordinator `
        -Scope $firstFixture.scope `
        -Operations $runtime.operations `
        -FallbackTarget $fallback
    Assert-True ($orphan.status -eq "failed") "recreated losing Zotero keys should block no-op"
    Assert-True (
        $orphan.issues[0].code -eq "cleanup_completed_orphan_zotero"
    ) "completed orphan should retain its typed code"
    $null = $runtime.state.liveKeys.Remove("DROP1111")

    $blockedFirst = New-CoordinatorCandidate `
        -Root (Join-Path $tempRoot "blocked-fifo") `
        -RetainKey "KEEPAAA1" `
        -RemoveKey "DROPAAA1" `
        -RetainAttachment "ATKEEPA1" `
        -RemoveAttachment "ATDROPA1"
    $blockedSecond = New-CoordinatorCandidate `
        -Root (Join-Path $tempRoot "blocked-fifo") `
        -RetainKey "KEEPBBB2" `
        -RemoveKey "DROPBBB2" `
        -RetainAttachment "ATKEEPB2" `
        -RemoveAttachment "ATDROPB2"
    $blockedPlanA = ConvertTo-CleanupPlan `
        -Candidate $blockedFirst.candidate `
        -Scope $blockedFirst.scope
    $blockedPlanB = ConvertTo-CleanupPlan `
        -Candidate $blockedSecond.candidate `
        -Scope $blockedSecond.scope
    $blockedPlanA.createdAt = "2026-07-30T00:00:00.0000000Z"
    $blockedPlanA.stateFingerprint = Get-CleanupStateFingerprint -Plan $blockedPlanA
    $blockedPlanB.createdAt = "2026-07-30T00:00:01.0000000Z"
    $blockedPlanB.stateFingerprint = Get-CleanupStateFingerprint -Plan $blockedPlanB
    $blockedRoot = Join-Path $blockedFirst.scope.zoteroDataDir `
        "zotero-paper-updater-transactions"
    Write-CoordinatorPlan -Plan $blockedPlanA -Path (Join-Path $blockedRoot "cleanup-v1-a.json")
    Write-CoordinatorPlan -Plan $blockedPlanB -Path (Join-Path $blockedRoot "cleanup-v1-b.json")
    $blockedRuntime = New-CoordinatorOperationTable -Plans @($blockedPlanA, $blockedPlanB)
    $normalReadAsset = $blockedRuntime.operations.ReadAssetEvidence
    $blockedRuntime.operations.ReadAssetEvidence = {
        param($Plan, $Expected)
        if ([string]$Plan.retain.parent.key -eq "KEEPAAA1") {
            $exception = [InvalidOperationException]::new("oldest pending plan drifted")
            $exception.Data["ZpuIssueCode"] = "cleanup_drift_hash"
            throw $exception
        }
        & $normalReadAsset $Plan $Expected
    }.GetNewClosure()
    $blockedResult = Invoke-CleanupRecoveryCoordinator `
        -Scope $blockedFirst.scope `
        -Operations $blockedRuntime.operations `
        -FallbackTarget $fallback
    Assert-True ($blockedResult.status -eq "failed") "oldest pending drift should block FIFO"
    Assert-True (
        $blockedRuntime.state.calls.Count -eq 0
    ) "a blocked oldest transaction must leave later transactions untouched"

    $busyRoot = Join-Path $tempRoot "busy"
    [IO.Directory]::CreateDirectory($busyRoot) | Out-Null
    $busyScope = [pscustomobject]@{
        zoteroDataDir = Join-Path $busyRoot "ZoteroData"
        paperRoot = Join-Path $busyRoot "papers"
    }
    [IO.Directory]::CreateDirectory($busyScope.zoteroDataDir) | Out-Null
    [IO.Directory]::CreateDirectory($busyScope.paperRoot) | Out-Null
    $mutexName = Get-CleanupLibraryMutexName -ZoteroDataDir $busyScope.zoteroDataDir
    $aliasPath = Join-Path $busyRoot "ZoteroAlias"
    $null = New-Item -ItemType Junction -Path $aliasPath -Target $busyScope.zoteroDataDir
    Assert-True (
        (Get-CleanupLibraryMutexName -ZoteroDataDir $aliasPath) -ceq $mutexName
    ) "junction aliases of one data directory should share a mutex"
    $readyPath = Join-Path $busyRoot "ready"
    $releasePath = Join-Path $busyRoot "release"
    $holderPath = Join-Path $busyRoot "holder.ps1"
    [IO.File]::WriteAllText($holderPath, @'
param([string]$Name,[string]$Ready,[string]$Release)
$mutex = [Threading.Mutex]::new($false,$Name)
$taken = $mutex.WaitOne(5000)
if (-not $taken) { exit 3 }
[IO.File]::WriteAllText($Ready,"ready")
try {
  $deadline = [DateTime]::UtcNow.AddSeconds(10)
  while (-not (Test-Path -LiteralPath $Release) -and [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 20
  }
}
finally {
  $mutex.ReleaseMutex()
  $mutex.Dispose()
}
'@, [Text.UTF8Encoding]::new($false))
    $holder = Start-Process `
        -FilePath (Get-Command pwsh).Source `
        -ArgumentList @("-NoProfile", "-File", $holderPath, $mutexName, $readyPath, $releasePath) `
        -WindowStyle Hidden `
        -PassThru
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        while (-not (Test-Path -LiteralPath $readyPath) -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 20
        }
        Assert-True (Test-Path -LiteralPath $readyPath) "child process should acquire the named mutex"
        $emptyRuntime = New-CoordinatorOperationTable -Plans @()
        $busyResult = Invoke-CleanupRecoveryCoordinator `
            -Scope $busyScope `
            -Operations $emptyRuntime.operations `
            -FallbackTarget ([pscustomobject]@{
                parentItemKey = $null
                attachmentKey = $null
                path = $busyScope.paperRoot
            })
        Assert-True ($busyResult.status -eq "failed") "a competing process should receive busy"
        Assert-True (
            $busyResult.issues[0].code -eq "cleanup_library_busy"
        ) "mutex contention should be a typed issue"
        Assert-True ($emptyRuntime.state.calls.Count -eq 0) "busy must make zero mutations"
    }
    finally {
        [IO.File]::WriteAllText($releasePath, "release")
        if (-not $holder.WaitForExit(5000)) {
            $holder.Kill($true)
            $holder.WaitForExit()
        }
        $holder.Dispose()
    }

    $json = $busyResult | ConvertTo-Json -Depth 20 -Compress | ConvertFrom-Json
    Assert-True (
        -not [string]::IsNullOrWhiteSpace([string]$json.issues[0].target.path)
    ) "public JSON issue should retain a stable target"

    Write-Output "All $passed cleanup-coordinator assertions passed."
}
finally {
    $resolved = [IO.Path]::GetFullPath($tempRoot)
    $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolved.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
