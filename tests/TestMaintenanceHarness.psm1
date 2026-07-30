Set-StrictMode -Version Latest

function New-MaintenanceTestHarness {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Creates an isolated command harness under the caller-provided temporary test directory."
    )]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [string]$TempRoot,

        [Parameter(Mandatory = $true)]
        [string]$AdapterPath
    )

    $sourceScriptRoot = Join-Path $RepoRoot "scripts"
    $harnessScriptRoot = Join-Path $TempRoot "harness\scripts"
    [IO.Directory]::CreateDirectory($harnessScriptRoot) | Out-Null

    [IO.File]::Copy(
        (Join-Path $sourceScriptRoot "maintain-library.ps1"),
        (Join-Path $harnessScriptRoot "maintain-library.ps1"),
        $true
    )
    foreach ($module in Get-ChildItem -LiteralPath $sourceScriptRoot -File -Filter "*.psm1") {
        [IO.File]::Copy(
            $module.FullName,
            (Join-Path $harnessScriptRoot $module.Name),
            $true
        )
    }
    [IO.File]::Copy(
        (Join-Path $sourceScriptRoot "ZoteroPaperUpdater.MaintenanceAdapters.psm1"),
        (Join-Path $harnessScriptRoot "ZoteroPaperUpdater.ProductionMaintenanceAdapters.psm1"),
        $true
    )
    [IO.File]::Copy(
        $AdapterPath,
        (Join-Path $harnessScriptRoot "ZoteroPaperUpdater.MaintenanceAdapters.psm1"),
        $true
    )

    Join-Path $harnessScriptRoot "maintain-library.ps1"
}

Export-ModuleMember -Function New-MaintenanceTestHarness
