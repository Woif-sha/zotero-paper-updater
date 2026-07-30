[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-TestScriptGroup {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Path,

        [int]$TimeoutMilliseconds = 60000
    )

    $runs = [Collections.Generic.List[object]]::new()
    try {
        foreach ($testPath in $Path) {
            $startInfo = [Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = (Get-Command pwsh -ErrorAction Stop).Source
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $startInfo.ArgumentList.Add("-NoProfile")
            $startInfo.ArgumentList.Add("-File")
            $startInfo.ArgumentList.Add($testPath)
            $process = [Diagnostics.Process]::new()
            $process.StartInfo = $startInfo
            if (-not $process.Start()) {
                throw "Failed to start test script '$testPath'."
            }
            $runs.Add([pscustomobject]@{
                path = $testPath
                process = $process
                deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
                stdout = $process.StandardOutput.ReadToEndAsync()
                stderr = $process.StandardError.ReadToEndAsync()
            })
        }

        foreach ($run in $runs) {
            $remaining = [int][Math]::Max(
                0,
                ($run.deadline - [DateTime]::UtcNow).TotalMilliseconds
            )
            if (-not $run.process.HasExited -and
                ($remaining -eq 0 -or -not $run.process.WaitForExit($remaining))) {
                throw "Test script '$($run.path)' exceeded $TimeoutMilliseconds milliseconds."
            }
            $run.process.WaitForExit()
        }

        foreach ($run in $runs) {
            $stdout = $run.stdout.GetAwaiter().GetResult().Trim()
            $stderr = $run.stderr.GetAwaiter().GetResult().Trim()
            if (-not [string]::IsNullOrWhiteSpace($stdout)) {
                Write-Output $stdout
            }
            if ($run.process.ExitCode -ne 0) {
                throw "Test script '$($run.path)' failed with exit code $($run.process.ExitCode): $stderr"
            }
            if (-not [string]::IsNullOrWhiteSpace($stderr)) {
                Write-Warning $stderr
            }
        }
    }
    finally {
        foreach ($run in $runs) {
            if (-not $run.process.HasExited) {
                $run.process.Kill($true)
                $run.process.WaitForExit()
            }
            $run.process.Dispose()
        }
    }
}

$testNames = @(
    "run-public-surface-contract-tests.ps1",
    "run-public-entry-integration-tests.ps1",
    "run-mcp-client-tests.ps1",
    "run-version-check-tests.ps1",
    "run-metadata-enrichment-tests.ps1",
    "run-live-metadata-adapter-tests.ps1",
    "run-crossref-source-tests.ps1",
    "run-zotero-writer-tests.ps1",
    "run-live-rename-aggregation-tests.ps1",
    "run-duplicate-cleanup-tests.ps1",
    "run-duplicate-consolidation-tests.ps1",
    "run-live-duplicate-cleanup-tests.ps1",
    "run-live-duplicate-cleanup-adapter-tests.ps1",
    "run-cleanup-orphan-proof-tests.ps1"
)
$testPaths = @($testNames | ForEach-Object { Join-Path $PSScriptRoot $_ })
Invoke-TestScriptGroup -Path $testPaths
$cleanupCoordinatorPath = Join-Path $PSScriptRoot "run-cleanup-coordinator-tests.ps1"
Invoke-TestScriptGroup -Path @($cleanupCoordinatorPath)
$fileRenamePath = Join-Path $PSScriptRoot "run-file-rename-tests.ps1"
Invoke-TestScriptGroup -Path @($fileRenamePath)
$maintenanceEntryPath = Join-Path $PSScriptRoot "run-maintenance-entry-tests.ps1"
$maintenanceEntryText = [IO.File]::ReadAllText($maintenanceEntryPath)
if (-not $maintenanceEntryText.Contains('$process.WaitForExit(60000)') -or
    -not $maintenanceEntryText.Contains('$process.Kill($true)')) {
    throw "Every public-entry child process must retain a 60-second timeout and tree kill."
}
& $maintenanceEntryPath
exit 0
