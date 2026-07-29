[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$entryPath = Join-Path $repoRoot "scripts\maintain-library.ps1"
$adapterPath = Join-Path $PSScriptRoot "fixtures\FakeMaintenanceAdapter.psm1"
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("zotero-maintenance-entry-test-" + [guid]::NewGuid().ToString("N"))
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

function Invoke-MaintenanceEntry {
    param(
        [string[]]$Arguments,
        [string]$Scenario = "unchanged",
        [string]$ScriptPath = $entryPath
    )

    $previousScenario = $env:ZPU_FAKE_SCENARIO
    $process = $null
    $env:ZPU_FAKE_SCENARIO = $Scenario
    try {
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = (Get-Command pwsh -ErrorAction Stop).Source
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in @("-NoProfile", "-File", $ScriptPath) + $Arguments) {
            $startInfo.ArgumentList.Add($argument)
        }

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            throw "Failed to start maintenance entry process."
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw "Maintenance entry process exceeded the 60-second test timeout."
        }
        $exitCode = $process.ExitCode
        $stdout = $stdoutTask.GetAwaiter().GetResult().Trim()
        $stderr = $stderrTask.GetAwaiter().GetResult().Trim()
    }
    finally {
        $env:ZPU_FAKE_SCENARIO = $previousScenario
        if ($null -ne $process) {
            $process.Dispose()
        }
    }

    [pscustomobject]@{
        exitCode = $exitCode
        stdout = $stdout
        stderr = $stderr
        json = $stdout | ConvertFrom-Json
    }
}

try {
    [System.IO.Directory]::CreateDirectory($paperRoot) | Out-Null
    [System.IO.Directory]::CreateDirectory($zoteroDataDir) | Out-Null

    $commonArguments = @(
        "-PaperRoot", $paperRoot,
        "-ZoteroDataDir", $zoteroDataDir,
        "-AdapterModulePath", $adapterPath
    )

    $all = Invoke-MaintenanceEntry -Arguments $commonArguments
    Assert-True -Condition ($all.exitCode -eq 0) -Message "unchanged all-library maintenance should exit 0"
    Assert-True -Condition ($all.json.schemaVersion -eq 1) -Message "result should use schema version 1"
    Assert-True -Condition ($all.json.scope.mode -eq "all") -Message "no selector should use all-library scope"
    Assert-True -Condition (-not $all.json.changed) -Message "successful no-op should report changed=false"
    Assert-True -Condition ($all.json.status -eq "succeeded") -Message "successful no-op should report succeeded"
    Assert-True -Condition ([string]::IsNullOrEmpty($all.stderr)) -Message "successful diagnostics should not pollute stderr"
    Assert-True -Condition ($all.json.summary.targetCount -eq 1) -Message "summary should count resolved targets"
    Assert-True -Condition ($all.json.results[0].status -eq "succeeded") -Message "target result should carry a stable status"
    Assert-True -Condition ($all.json.results[0].PSObject.Properties.Name -contains "actions") -Message "target result should always include actions"
    Assert-True -Condition ($all.json.results[0].PSObject.Properties.Name -contains "issues") -Message "target result should always include issues"

    $byItem = Invoke-MaintenanceEntry -Arguments ($commonArguments + @("-ItemKey", "PARENT9"))
    Assert-True -Condition ($byItem.json.scope.mode -eq "itemKey") -Message "ItemKey should select item scope"
    Assert-True -Condition ($byItem.json.scope.selector -eq "PARENT9") -Message "ItemKey scope should preserve the selector"
    Assert-True -Condition ($byItem.json.results[0].target.parentItemKey -eq "PARENT9") -Message "fake adapter should receive item scope"

    $paperPath = Join-Path $paperRoot "paper.pdf"
    $byPath = Invoke-MaintenanceEntry -Arguments ($commonArguments + @("-Path", $paperPath))
    Assert-True -Condition ($byPath.json.scope.mode -eq "path") -Message "Path should select path scope"
    Assert-True -Condition ($byPath.json.scope.selector -eq $paperPath) -Message "Path scope should preserve the selector"

    $sparseTarget = Invoke-MaintenanceEntry -Arguments $commonArguments -Scenario "sparse-target"
    Assert-True -Condition ($sparseTarget.exitCode -eq 0) -Message "a target with one available identifier should be valid"
    Assert-True -Condition ($sparseTarget.json.results[0].target.PSObject.Properties.Name.Count -eq 3) -Message "target should always expose three stable identifier fields"
    Assert-True -Condition ($null -eq $sparseTarget.json.results[0].target.attachmentKey) -Message "unavailable target identifiers should be null"

    $partial = Invoke-MaintenanceEntry -Arguments $commonArguments -Scenario "partial"
    Assert-True -Condition ($partial.exitCode -eq 2) -Message "partial maintenance should exit 2"
    Assert-True -Condition ($partial.json.status -eq "partial") -Message "partial maintenance should report partial"
    Assert-True -Condition $partial.json.changed -Message "actions should make changed=true"
    Assert-True -Condition ($partial.json.summary.actionsByCategory.modified -eq 1) -Message "summary should count action categories"
    Assert-True -Condition ($partial.json.results[0].actions[0].PSObject.Properties.Name.Count -eq 6) -Message "actions should expose the stable six-field contract"
    Assert-True -Condition ($partial.json.results[0].issues[0].PSObject.Properties.Name.Count -eq 5) -Message "issues should expose the stable five-field contract"

    $targetFailure = Invoke-MaintenanceEntry -Arguments $commonArguments -Scenario "target-failure"
    Assert-True -Condition ($targetFailure.exitCode -eq 1) -Message "an unexpected adapter exception should fail the run"
    Assert-True -Condition ($targetFailure.json.status -eq "failed") -Message "an unexpected adapter exception should not be downgraded to partial"
    Assert-True -Condition ($targetFailure.json.issues[0].evidence.Count -ge 1) -Message "unexpected failures should preserve exception evidence"

    $targetBlocked = Invoke-MaintenanceEntry -Arguments $commonArguments -Scenario "target-blocked"
    Assert-True -Condition ($targetBlocked.exitCode -eq 2) -Message "one blocked target should make the run partial"
    Assert-True -Condition ($targetBlocked.json.summary.targetCount -eq 2) -Message "independent targets should both be processed"
    Assert-True -Condition ($targetBlocked.json.summary.failedCount -eq 1) -Message "blocked target should be counted as failed"
    Assert-True -Condition ($targetBlocked.json.summary.succeededCount -eq 1) -Message "independent target should continue to success"

    $progressThenCrash = Invoke-MaintenanceEntry -Arguments $commonArguments -Scenario "progress-then-crash"
    Assert-True -Condition ($progressThenCrash.exitCode -eq 1) -Message "an unexpected later crash should fail the run"
    Assert-True -Condition $progressThenCrash.json.changed -Message "completed actions should survive a later crash"
    Assert-True -Condition ($progressThenCrash.json.summary.targetCount -eq 1) -Message "completed targets should survive a later crash"
    Assert-True -Condition ($progressThenCrash.json.summary.actionCount -eq 1) -Message "completed actions should remain in the summary"
    Assert-True -Condition ($progressThenCrash.json.issues[0].code -eq "maintenance_run_failed") -Message "later crash should remain a run-level failure"

    $progressThenInvalid = Invoke-MaintenanceEntry -Arguments $commonArguments -Scenario "progress-then-invalid-result"
    Assert-True -Condition ($progressThenInvalid.exitCode -eq 1) -Message "an invalid later record should fail the run"
    Assert-True -Condition $progressThenInvalid.json.changed -Message "completed actions should survive a later contract error"
    Assert-True -Condition ($progressThenInvalid.json.summary.targetCount -eq 1) -Message "completed targets should survive a later contract error"
    Assert-True -Condition ($progressThenInvalid.json.summary.actionCount -eq 1) -Message "completed action summary should survive a later contract error"

    $inconsistent = Invoke-MaintenanceEntry -Arguments $commonArguments -Scenario "inconsistent"
    Assert-True -Condition ($inconsistent.exitCode -eq 1) -Message "an inconsistent adapter result should fail the run"
    Assert-True -Condition ($inconsistent.json.status -eq "failed") -Message "succeeded plus unresolved issues should be rejected"
    Assert-True -Condition ($inconsistent.json.issues[0].message -match "succeeded target") -Message "inconsistent result should explain the violated invariant"

    $invalid = Invoke-MaintenanceEntry -Arguments ($commonArguments + @("-ItemKey", "PARENT9", "-Path", $paperPath))
    Assert-True -Condition ($invalid.exitCode -eq 1) -Message "dual selectors should exit 1"
    Assert-True -Condition ($invalid.json.status -eq "failed") -Message "dual selectors should return failed JSON"
    Assert-True -Condition ($invalid.json.issues[0].code -eq "selectors_mutually_exclusive") -Message "dual selectors should have a stable issue code"
    Assert-True -Condition ($invalid.stdout.StartsWith("{") -and $invalid.stdout.EndsWith("}")) -Message "stdout should contain one JSON document"

    $failed = Invoke-MaintenanceEntry -Arguments $commonArguments -Scenario "run-failure"
    Assert-True -Condition ($failed.exitCode -eq 1) -Message "run-level adapter failure should exit 1"
    Assert-True -Condition ($failed.json.status -eq "failed") -Message "run-level adapter failure should report failed"
    Assert-True -Condition ($failed.json.issues[0].code -eq "maintenance_run_failed") -Message "run-level failure should have a stable issue code"
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($failed.stderr)) -Message "run-level failure diagnostics should be written to stderr"

    $liveAdapterUnavailable = Invoke-MaintenanceEntry -Arguments @(
        "-PaperRoot", $paperRoot,
        "-ZoteroDataDir", $zoteroDataDir
    )
    Assert-True -Condition ($liveAdapterUnavailable.exitCode -eq 1) -Message "unfinished live resolution should fail explicitly"
    Assert-True -Condition ($liveAdapterUnavailable.json.issues[0].message -match "issue #10") -Message "live adapter failure should name the blocked implementation"

    $isolatedEntryRoot = Join-Path $tempRoot "isolated-entry"
    [System.IO.Directory]::CreateDirectory($isolatedEntryRoot) | Out-Null
    $isolatedEntryPath = Join-Path $isolatedEntryRoot "maintain-library.ps1"
    [System.IO.File]::Copy($entryPath, $isolatedEntryPath)
    $bootstrapFailure = Invoke-MaintenanceEntry -Arguments @() -ScriptPath $isolatedEntryPath
    Assert-True -Condition ($bootstrapFailure.exitCode -eq 1) -Message "missing workflow module should exit 1"
    Assert-True -Condition ($bootstrapFailure.json.status -eq "failed") -Message "missing workflow module should still emit failed JSON"
    Assert-True -Condition ($bootstrapFailure.json.issues[0].code -eq "maintenance_run_failed") -Message "bootstrap failure should preserve the stable run issue code"

    $unknownArgument = Invoke-MaintenanceEntry -Arguments ($commonArguments + @("-UnknownOption", "value"))
    Assert-True -Condition ($unknownArgument.exitCode -eq 1) -Message "unsupported arguments should exit 1"
    Assert-True -Condition ($unknownArgument.json.issues[0].code -eq "invalid_arguments") -Message "unsupported arguments should return JSON with a stable issue code"

    $missingValue = Invoke-MaintenanceEntry -Arguments @("-ItemKey")
    Assert-True -Condition ($missingValue.exitCode -eq 1) -Message "a known argument without a value should exit 1"
    Assert-True -Condition ($missingValue.json.issues[0].code -eq "invalid_arguments") -Message "a missing argument value should return JSON"

    Write-Output "All $passed maintenance-entry assertions passed."
}
finally {
    $resolvedTempRoot = [System.IO.Path]::GetFullPath($tempRoot)
    $resolvedSystemTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($resolvedTempRoot.StartsWith($resolvedSystemTemp, [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
