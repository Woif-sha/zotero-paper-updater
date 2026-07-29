[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$entryPath = Join-Path $repoRoot "scripts\maintain-library.ps1"
$adapterPath = Join-Path $PSScriptRoot "fixtures\FakeMetadataEnrichmentAdapter.psm1"
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
    ("zotero-metadata-enrichment-test-" + [guid]::NewGuid().ToString("N"))
$paperRoot = Join-Path $tempRoot "papers"
$zoteroDataDir = Join-Path $tempRoot "ZoteroData"
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

function Invoke-MetadataEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Scenario
    )

    $callLogPath = Join-Path $tempRoot "$Scenario-calls.jsonl"
    $previousScenario = $env:ZPU_METADATA_SCENARIO
    $previousCallLog = $env:ZPU_METADATA_CALL_LOG
    $process = $null
    $env:ZPU_METADATA_SCENARIO = $Scenario
    $env:ZPU_METADATA_CALL_LOG = $callLogPath
    try {
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = (Get-Command pwsh -ErrorAction Stop).Source
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in @(
            "-NoProfile",
            "-File", $entryPath,
            "-PaperRoot", $paperRoot,
            "-ZoteroDataDir", $zoteroDataDir,
            "-AdapterModulePath", $adapterPath
        )) {
            $startInfo.ArgumentList.Add($argument)
        }

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            throw "Failed to start metadata enrichment entry process."
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw "Metadata enrichment entry process exceeded the 60-second test timeout."
        }
        $exitCode = $process.ExitCode
        $stdout = $stdoutTask.GetAwaiter().GetResult().Trim()
        $stderr = $stderrTask.GetAwaiter().GetResult().Trim()
    }
    finally {
        $env:ZPU_METADATA_SCENARIO = $previousScenario
        $env:ZPU_METADATA_CALL_LOG = $previousCallLog
        if ($null -ne $process) {
            $process.Dispose()
        }
    }

    $calls = if (Test-Path -LiteralPath $callLogPath) {
        @(
            [System.IO.File]::ReadAllLines($callLogPath) |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                ForEach-Object { $_ | ConvertFrom-Json }
        )
    }
    else {
        @()
    }

    [pscustomobject]@{
        exitCode = $exitCode
        stdout = $stdout
        stderr = $stderr
        json = $stdout | ConvertFrom-Json
        calls = $calls
    }
}

try {
    [System.IO.Directory]::CreateDirectory($paperRoot) | Out-Null
    [System.IO.Directory]::CreateDirectory($zoteroDataDir) | Out-Null

    $doiMatch = Invoke-MetadataEntry -Scenario "doi-match"
    $doiQueries = @($doiMatch.calls | Where-Object { $_.operation -eq "query" })
    $doiWrites = @($doiMatch.calls | Where-Object { $_.operation -eq "write" })
    Assert-True -Condition ($doiMatch.exitCode -eq 0) -Message "an exact DOI match should succeed"
    Assert-True -Condition ($doiQueries.Count -eq 1) -Message "each parent should be queried at most once"
    Assert-True -Condition ($doiQueries[0].payload.kind -eq "doi") -Message "DOI should take precedence"
    Assert-True -Condition ($doiQueries[0].payload.value -eq "10.1000/exact") -Message "the full DOI should be queried"
    Assert-True -Condition ($doiWrites.Count -eq 1) -Message "an exact reliable formal match should be written once"
    Assert-True -Condition ($doiWrites[0].payload.expectedVersion -eq 7) -Message "writes should use optimistic versioning"
    Assert-True -Condition ($doiWrites[0].payload.fields.reportNumber -eq "R-42") -Message "all source-provided bibliographic fields should be written"
    Assert-True -Condition ($doiWrites[0].payload.fields.PSObject.Properties.Name -notcontains "extra") -Message "source data should not overwrite user Extra"
    Assert-True -Condition ($doiWrites[0].payload.fields.PSObject.Properties.Name -notcontains "tags") -Message "source data should not overwrite user tags"
    Assert-True -Condition ($doiMatch.json.results[0].actions[0].category -eq "modified") -Message "metadata completion should be modified"
    Assert-True -Condition ($doiMatch.json.results[0].actions[0].kind -eq "metadata_completed") -Message "metadata action kind should be stable"
    Assert-True -Condition ($doiMatch.json.results[0].actions[0].before.date -eq "2024") -Message "action before should reflect stored metadata"
    Assert-True -Condition ($doiMatch.json.results[0].actions[0].after.date -eq "2025") -Message "action after should reflect written metadata"
    Assert-True -Condition ($doiMatch.json.results[0].actions[0].evidence.Count -eq 2) -Message "action should preserve source evidence"

    $titleMatch = Invoke-MetadataEntry -Scenario "title-match"
    $titleQueries = @($titleMatch.calls | Where-Object { $_.operation -eq "query" })
    Assert-True -Condition ($titleQueries.Count -eq 1) -Message "title lookup should not retry a fallback"
    Assert-True -Condition ($titleQueries[0].payload.kind -eq "title_first_author") -Message "missing DOI should use title plus first author"
    Assert-True -Condition ($titleQueries[0].payload.title -eq "Exact Paper Title") -Message "title lookup should use the complete title"
    Assert-True -Condition ($titleQueries[0].payload.firstAuthor -eq "Ada Lovelace") -Message "title lookup should use the first author"

    foreach ($scenario in @("no-match", "inexact-match", "unreliable-match", "informal-match")) {
        $noWrite = Invoke-MetadataEntry -Scenario $scenario
        Assert-True -Condition ($noWrite.exitCode -eq 0) -Message "$scenario should be a successful no-op"
        Assert-True -Condition (-not $noWrite.json.changed) -Message "$scenario should not modify metadata"
        Assert-True -Condition ($noWrite.json.summary.unresolvedCount -eq 0) -Message "$scenario should not create an issue"
        Assert-True -Condition ($noWrite.json.results[0].actions.Count -eq 0) -Message "$scenario should return no action"
        Assert-True -Condition (@($noWrite.calls | Where-Object { $_.operation -eq "query" }).Count -eq 1) -Message "$scenario should query once"
        Assert-True -Condition (@($noWrite.calls | Where-Object { $_.operation -eq "write" }).Count -eq 0) -Message "$scenario should not write"
    }

    $unchanged = Invoke-MetadataEntry -Scenario "exact-unchanged"
    Assert-True -Condition ($unchanged.exitCode -eq 0) -Message "an unchanged exact reliable formal match should succeed"
    Assert-True -Condition ($unchanged.json.status -eq "succeeded") -Message "an unchanged match should keep the run succeeded"
    Assert-True -Condition (-not $unchanged.json.changed) -Message "an unchanged match should report changed=false"
    Assert-True -Condition ($unchanged.json.results[0].actions.Count -eq 0) -Message "an unchanged match should return no actions"
    Assert-True -Condition (@($unchanged.calls | Where-Object { $_.operation -eq "query" }).Count -eq 1) -Message "an unchanged match should query once"
    Assert-True -Condition (@($unchanged.calls | Where-Object { $_.operation -eq "write" }).Count -eq 0) -Message "an unchanged match should not call the write adapter"

    $reordered = Invoke-MetadataEntry -Scenario "property-order-unchanged"
    Assert-True -Condition ($reordered.exitCode -eq 0) -Message "semantically equal metadata with reordered properties should succeed"
    Assert-True -Condition (-not $reordered.json.changed) -Message "property order alone should not count as a metadata change"
    Assert-True -Condition (@($reordered.calls | Where-Object { $_.operation -eq "write" }).Count -eq 0) -Message "property order alone should not trigger a write"

    $sparse = Invoke-MetadataEntry -Scenario "sparse-record"
    $sparseWrite = @($sparse.calls | Where-Object { $_.operation -eq "write" })[0].payload
    Assert-True -Condition ($sparseWrite.fields.PSObject.Properties.Name -notcontains "volume") -Message "null source fields should not be sent"
    Assert-True -Condition ($sparseWrite.fields.PSObject.Properties.Name -notcontains "issue") -Message "empty-string source fields should stay unchanged"
    Assert-True -Condition ($sparseWrite.fields.PSObject.Properties.Name -notcontains "pages") -Message "whitespace-only source fields should stay unchanged"
    Assert-True -Condition ($sparseWrite.PSObject.Properties.Name -notcontains "itemType") -Message "item type should be absent without explicit source data"
    Assert-True -Condition ($sparseWrite.PSObject.Properties.Name -notcontains "userState") -Message "user state should never be in the write request"

    $typed = Invoke-MetadataEntry -Scenario "explicit-item-type"
    $typedWrite = @($typed.calls | Where-Object { $_.operation -eq "write" })[0].payload
    Assert-True -Condition ($typedWrite.itemType -eq "conferencePaper") -Message "explicit source item type should be written"
    Assert-True -Condition ($typed.json.results[0].actions[0].before.itemType -eq "journalArticle") -Message "action should capture prior item type"
    Assert-True -Condition ($typed.json.results[0].actions[0].after.itemType -eq "conferencePaper") -Message "action should capture written item type"

    $conflict = Invoke-MetadataEntry -Scenario "version-conflict"
    Assert-True -Condition ($conflict.exitCode -eq 2) -Message "a version conflict should fail the target explicitly"
    Assert-True -Condition ($conflict.json.status -eq "partial") -Message "one explicit target conflict should make the run partial"
    Assert-True -Condition ($conflict.json.results[0].status -eq "failed") -Message "a version conflict should fail the target"
    Assert-True -Condition ($conflict.json.results[0].issues[0].code -eq "metadata_version_conflict") -Message "version conflicts should have a stable issue code"
    Assert-True -Condition (-not $conflict.json.changed) -Message "a rejected versioned write should not report a change"

    Write-Output "All $passed metadata-enrichment assertions passed."
}
finally {
    $resolvedTempRoot = [System.IO.Path]::GetFullPath($tempRoot)
    $resolvedSystemTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($resolvedTempRoot.StartsWith($resolvedSystemTemp, [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
