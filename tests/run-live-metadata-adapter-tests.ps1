[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$adapterPath = Join-Path $PSScriptRoot "fixtures\FakeLiveMetadataAdapter.psm1"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("zotero-live-metadata-adapter-test-" + [guid]::NewGuid().ToString("N"))
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

try {
    $storageDirectory = Join-Path $zoteroDataDir "storage\ATTACH22"
    [IO.Directory]::CreateDirectory($storageDirectory) | Out-Null
    [IO.Directory]::CreateDirectory($paperRoot) | Out-Null
    $bytes = [Text.Encoding]::ASCII.GetBytes("%PDF-production-wiring")
    [IO.File]::WriteAllBytes((Join-Path $storageDirectory "Canonical Paper.pdf"), $bytes)
    [IO.File]::WriteAllBytes((Join-Path $paperRoot "download.pdf"), $bytes)

    $previousCallLog = $env:ZPU_LIVE_ADAPTER_CALL_LOG
    $env:ZPU_LIVE_ADAPTER_CALL_LOG = $callLogPath
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
            "-Path", (Join-Path $paperRoot "download.pdf"),
            "-PaperRoot", $paperRoot,
            "-ZoteroDataDir", $zoteroDataDir
        )) {
            $startInfo.ArgumentList.Add($argument)
        }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            throw "Failed to start the live metadata adapter contract test."
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw "Live metadata adapter contract test exceeded 60 seconds."
        }
        $exitCode = $process.ExitCode
        $stdout = $stdoutTask.GetAwaiter().GetResult().Trim()
        $stderr = $stderrTask.GetAwaiter().GetResult().Trim()
        $process.Dispose()
    }
    finally {
        $env:ZPU_LIVE_ADAPTER_CALL_LOG = $previousCallLog
    }

    $result = $stdout | ConvertFrom-Json
    $calls = @(
        [IO.File]::ReadAllLines($callLogPath) |
            ForEach-Object { $_ | ConvertFrom-Json }
    )
    $reads = @($calls | Where-Object { $_.operation -eq "read" })
    $queries = @($calls | Where-Object { $_.operation -eq "query" })
    $mcpCalls = @($calls | Where-Object { $_.operation -eq "mcp" })

    Assert-True -Condition ($exitCode -eq 0) -Message "production metadata wiring should succeed through the public entry"
    Assert-True -Condition ([string]::IsNullOrWhiteSpace($stderr)) -Message "successful production wiring should not write stderr"
    Assert-True -Condition ($reads.Count -eq 2) -Message "production wiring should read before and after the write"
    Assert-True -Condition ($queries.Count -eq 1) -Message "production wiring should query exactly once per parent"
    Assert-True -Condition ($queries[0].payload.uri -match "/works/10\.1000%2Fproduction$") -Message "production wiring should prefer the live DOI"
    Assert-True -Condition ($mcpCalls.Count -eq 1) -Message "production wiring should call the MCP write transport once"
    Assert-True -Condition ($mcpCalls[0].payload.expectedVersion -eq 7) -Message "MCP write should carry the live expectedVersion"
    Assert-True -Condition ($result.status -eq "succeeded") -Message "the public result should remain succeeded"
    Assert-True -Condition $result.changed -Message "verified metadata completion should report changed"
    Assert-True -Condition ($result.results[0].actions.Count -eq 2) -Message "metadata and rename facts should both be preserved"
    Assert-True -Condition ($result.results[0].actions[0].kind -eq "metadata_completed") -Message "metadata should run before local rename"
    Assert-True -Condition ($result.results[0].actions[0].before.date -eq "2024") -Message "action before should use the live pre-write snapshot"
    Assert-True -Condition ($result.results[0].actions[0].after.date -eq "2025") -Message "action after should use the verified live reread"
    Assert-True -Condition ($result.results[0].actions[0].evidence[0] -eq "https://doi.org/10.1000/production") -Message "action evidence should identify the formal record"
    Assert-True -Condition ($result.results[0].actions[1].kind -eq "local_pdf_renamed") -Message "rename should follow metadata completion"
    Assert-True -Condition ($result.results[0].actions[1].before.path -eq (Join-Path $paperRoot "download.pdf")) -Message "rename should preserve the resolved source path"
    Assert-True -Condition ($result.results[0].actions[1].after.path -eq (Join-Path $paperRoot "Canonical Paper.pdf")) -Message "rename should use the storage basename"
    Assert-True -Condition ($result.results[0].actions[1].before.sha256 -eq $result.results[0].actions[1].after.sha256) -Message "rename should preserve SHA-256"
    Assert-True -Condition ($result.summary.actionsByCategory.modified -eq 1) -Message "metadata should remain a modified action"
    Assert-True -Condition ($result.summary.actionsByCategory.renamed -eq 1) -Message "rename should remain a renamed action"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $paperRoot "Canonical Paper.pdf") -PathType Leaf) -Message "the canonical local PDF should exist"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $paperRoot "download.pdf"))) -Message "the old local PDF should be absent"

    Write-Output "All $passed live-metadata-adapter assertions passed."
}
finally {
    $resolvedTempRoot = [IO.Path]::GetFullPath($tempRoot)
    $resolvedSystemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolvedTempRoot.StartsWith($resolvedSystemTemp, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
