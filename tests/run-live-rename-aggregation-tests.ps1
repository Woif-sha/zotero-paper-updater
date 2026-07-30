[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$adapterPath = Join-Path $PSScriptRoot "fixtures\FakeLiveMetadataAdapter.psm1"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("zotero-live-rename-aggregation-test-" + [guid]::NewGuid().ToString("N"))
$harnessModulePath = Join-Path $PSScriptRoot "TestMaintenanceHarness.psm1"
Import-Module -Name $harnessModulePath -Force
$entryPath = New-MaintenanceTestHarness `
    -RepoRoot $repoRoot `
    -TempRoot $tempRoot `
    -AdapterPath $adapterPath
$paperRoot = Join-Path $tempRoot "papers"
$zoteroDataDir = Join-Path $tempRoot "ZoteroData"
$callLogPath = Join-Path $tempRoot "calls.jsonl"
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

try {
    $storageDirectory = Join-Path $zoteroDataDir "storage\ATTACH22"
    [IO.Directory]::CreateDirectory($storageDirectory) | Out-Null
    [IO.Directory]::CreateDirectory($paperRoot) | Out-Null
    $bytes = [Text.Encoding]::ASCII.GetBytes("%PDF-production-wiring")
    [IO.File]::WriteAllBytes((Join-Path $storageDirectory "Canonical Paper.pdf"), $bytes)
    [IO.File]::WriteAllBytes((Join-Path $paperRoot "download.pdf"), $bytes)

    $previousCallLog = $env:ZPU_LIVE_ADAPTER_CALL_LOG
    $previousScenario = $env:ZPU_LIVE_ADAPTER_SCENARIO
    $env:ZPU_LIVE_ADAPTER_CALL_LOG = $callLogPath
    $env:ZPU_LIVE_ADAPTER_SCENARIO = "rename-source-missing"
    try {
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = (Get-Command pwsh -ErrorAction Stop).Source
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in @(
            "-NoProfile",
            "-File", $entryPath,
            "-ItemKey", "PARENT22",
            "-PaperRoot", $paperRoot,
            "-ZoteroDataDir", $zoteroDataDir
        )) {
            $startInfo.ArgumentList.Add($argument)
        }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            throw "Failed to start the live rename aggregation test."
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw "Live rename aggregation test exceeded 60 seconds."
        }
        $exitCode = $process.ExitCode
        $stdout = $stdoutTask.GetAwaiter().GetResult().Trim()
        $stderr = $stderrTask.GetAwaiter().GetResult().Trim()
        $process.Dispose()
    }
    finally {
        $env:ZPU_LIVE_ADAPTER_CALL_LOG = $previousCallLog
        $env:ZPU_LIVE_ADAPTER_SCENARIO = $previousScenario
    }

    $result = $stdout | ConvertFrom-Json
    Assert-True -Condition ($exitCode -eq 2) -Message "rename drift should make only the target partial"
    Assert-True -Condition ([string]::IsNullOrWhiteSpace($stderr)) -Message "a typed partial result should not write stderr"
    Assert-True -Condition ($result.status -eq "partial") -Message "the envelope should aggregate the partial rename status"
    Assert-True -Condition ($result.results[0].actions.Count -eq 1) -Message "the completed metadata action must survive a later rename issue"
    Assert-True -Condition ($result.results[0].actions[0].kind -eq "metadata_completed") -Message "the earlier stage fact should remain typed"
    Assert-True -Condition ($result.results[0].issues.Count -eq 1) -Message "the later rename issue should be preserved"
    Assert-True -Condition ($result.results[0].issues[0].code -eq "local_pdf_missing") -Message "rename drift should keep its explicit classification"
    Assert-True -Condition $result.changed -Message "an earlier completed stage should keep the envelope changed"

    Write-Output "All $passed live-rename-aggregation assertions passed."
}
finally {
    $resolvedTempRoot = [IO.Path]::GetFullPath($tempRoot)
    $resolvedSystemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolvedTempRoot.StartsWith($resolvedSystemTemp, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
