[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) (
    "zotero-public-entry-integration-" + [guid]::NewGuid().ToString("N")
)
$paperRoot = Join-Path $tempRoot "papers"
$zoteroDataDir = Join-Path $tempRoot "ZoteroData"
$adapterPath = Join-Path $PSScriptRoot "fixtures\FakePublicMaintenanceAdapter.psm1"
$cleanupStatePath = Join-Path $tempRoot "cleanup.completed"
$passed = 0

Import-Module -Name (Join-Path $PSScriptRoot "TestMaintenanceHarness.psm1") -Force
$entryPath = New-MaintenanceTestHarness `
    -RepoRoot $repoRoot `
    -TempRoot $tempRoot `
    -AdapterPath $adapterPath

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

function Invoke-PublicEntry {
    param(
        [string[]]$Arguments,
        [string]$Scenario = "noop"
    )

    $oldScenario = $env:ZPU_PUBLIC_SCENARIO
    $oldCleanupState = $env:ZPU_PUBLIC_CLEANUP_STATE
    $process = $null
    $env:ZPU_PUBLIC_SCENARIO = $Scenario
    $env:ZPU_PUBLIC_CLEANUP_STATE = $cleanupStatePath
    try {
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = (Get-Command pwsh -ErrorAction Stop).Source
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in @("-NoProfile", "-File", $entryPath) + $Arguments) {
            $startInfo.ArgumentList.Add($argument)
        }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            throw "Failed to start the public maintenance command."
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw "Public maintenance command exceeded 60 seconds."
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult().Trim()
        $stderr = $stderrTask.GetAwaiter().GetResult().Trim()
        [pscustomobject]@{
            exitCode = $process.ExitCode
            stdout = $stdout
            stderr = $stderr
            json = $stdout | ConvertFrom-Json
        }
    }
    finally {
        $env:ZPU_PUBLIC_SCENARIO = $oldScenario
        $env:ZPU_PUBLIC_CLEANUP_STATE = $oldCleanupState
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}

try {
    [IO.Directory]::CreateDirectory($paperRoot) | Out-Null
    $storageRoot = Join-Path $zoteroDataDir "storage\ATTACH23"
    [IO.Directory]::CreateDirectory($storageRoot) | Out-Null
    $managedBytes = [Text.Encoding]::ASCII.GetBytes("%PDF-public-contract")
    $storagePath = Join-Path $storageRoot "Canonical.pdf"
    $localPath = Join-Path $paperRoot "download.pdf"
    [IO.File]::WriteAllBytes($storagePath, $managedBytes)
    [IO.File]::WriteAllBytes($localPath, $managedBytes)
    $common = @("-PaperRoot", $paperRoot, "-ZoteroDataDir", $zoteroDataDir)

    $all = Invoke-PublicEntry -Arguments $common
    Assert-True ($all.exitCode -eq 0 -and $all.json.scope.mode -eq "all") `
        "default all-library invocation should succeed: $($all | ConvertTo-Json -Depth 8 -Compress)"

    $item = Invoke-PublicEntry -Arguments ($common + @("-ItemKey", "PARENT23"))
    Assert-True ($item.exitCode -eq 0 -and $item.json.scope.mode -eq "itemKey") `
        "ItemKey invocation should maintain one existing item"

    $path = Invoke-PublicEntry -Arguments ($common + @("-Path", $localPath))
    Assert-True ($path.exitCode -eq 0 -and $path.json.scope.mode -eq "path") `
        "Path invocation should maintain one existing local PDF"

    $firstCleanup = Invoke-PublicEntry -Arguments $common -Scenario "cleanup"
    Assert-True ($firstCleanup.exitCode -eq 0 -and
        $firstCleanup.json.summary.actionsByCategory.deleted -eq 1 -and
        $null -eq $firstCleanup.json.results[-1].actions[0].after) `
        "first strict cleanup should emit one complete logical deletion"

    $secondCleanup = Invoke-PublicEntry -Arguments $common -Scenario "cleanup"
    Assert-True ($secondCleanup.exitCode -eq 0 -and
        -not $secondCleanup.json.changed -and
        $secondCleanup.json.summary.actionCount -eq 0) `
        "completed cleanup should rerun as an idempotent no-op"

    $metadataNoHit = Invoke-PublicEntry -Arguments $common -Scenario "metadata-nohit"
    Assert-True ($metadataNoHit.exitCode -eq 0 -and
        -not $metadataNoHit.json.changed -and
        $metadataNoHit.json.summary.unresolvedCount -eq 0) `
        "metadata no-hit should be a successful no-op"

    $canonicalCollision = Join-Path $paperRoot "Canonical.pdf"
    [IO.File]::WriteAllBytes(
        $canonicalCollision,
        [Text.Encoding]::ASCII.GetBytes("%PDF-different")
    )
    $collision = Invoke-PublicEntry `
        -Arguments ($common + @("-ItemKey", "PARENT23")) `
        -Scenario "rename-collision"
    Assert-True ($collision.exitCode -eq 2 -and
        @($collision.json.results.issues.code) -contains "rename_target_conflict") `
        "a different-hash canonical filename should freeze the target"
    Remove-Item -LiteralPath $canonicalCollision -Force

    $duplicateLocal = Join-Path $paperRoot "duplicate.pdf"
    [IO.File]::WriteAllBytes($duplicateLocal, $managedBytes)
    $ambiguous = Invoke-PublicEntry -Arguments ($common + @("-Path", $localPath))
    Assert-True ($ambiguous.exitCode -eq 2 -and
        @($ambiguous.json.results.issues.code) -contains "association_ambiguous") `
        "a non-unique local SHA mapping should be ambiguous"
    Remove-Item -LiteralPath $duplicateLocal -Force

    $dual = Invoke-PublicEntry -Arguments (
        $common + @("-ItemKey", "PARENT23", "-Path", $localPath)
    )
    Assert-True ($dual.exitCode -eq 1 -and
        $dual.json.issues[0].code -eq "selectors_mutually_exclusive" -and
        $dual.stdout.StartsWith("{") -and $dual.stdout.EndsWith("}")) `
        "dual selectors should fail with one stable JSON document"

    $oldBackdoor = Invoke-PublicEntry -Arguments (
        $common + @("-AdapterModulePath", $adapterPath)
    )
    Assert-True ($oldBackdoor.exitCode -eq 1 -and
        $oldBackdoor.json.issues[0].code -eq "invalid_arguments") `
        "the former adapter injection option must be rejected"

    Write-Output "All $passed public-entry integration scenarios passed."
}
finally {
    $resolved = [IO.Path]::GetFullPath($tempRoot)
    $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolved.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
