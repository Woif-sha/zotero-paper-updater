[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$entryPath = Join-Path $repoRoot "scripts\maintain-library.ps1"
$adapterPath = Join-Path $PSScriptRoot "fixtures\FakeDuplicateCleanupAdapter.psm1"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("zotero-live-duplicate-cleanup-test-" + [guid]::NewGuid().ToString("N"))
$paperRoot = Join-Path $tempRoot "papers"
$zoteroDataDir = Join-Path $tempRoot "ZoteroData"
$callLog = Join-Path $tempRoot "calls.log"
$passed = 0

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:passed++
}

try {
    [IO.Directory]::CreateDirectory($paperRoot) | Out-Null
    foreach ($key in @("ATTACH33", "ATTACH44")) {
        $storageDirectory = Join-Path $zoteroDataDir "storage\$key"
        [IO.Directory]::CreateDirectory($storageDirectory) | Out-Null
        $bytes = [Text.Encoding]::ASCII.GetBytes("%PDF-$key")
        [IO.File]::WriteAllBytes((Join-Path $storageDirectory "$key.pdf"), $bytes)
        [IO.File]::WriteAllBytes((Join-Path $paperRoot "$key.pdf"), $bytes)
    }

    $oldLog = $env:ZPU_CLEANUP_CALL_LOG
    $env:ZPU_CLEANUP_CALL_LOG = $callLog
    try {
        $output = & pwsh -NoProfile -File $entryPath `
            -PaperRoot $paperRoot `
            -ZoteroDataDir $zoteroDataDir `
            -AdapterModulePath $adapterPath
        $exitCode = $LASTEXITCODE
    }
    finally {
        $env:ZPU_CLEANUP_CALL_LOG = $oldLog
    }

    $result = $output | ConvertFrom-Json
    $calls = @(Get-Content -LiteralPath $callLog)
    Assert-True -Condition ($exitCode -eq 0) -Message "a completed run-level cleanup should succeed (exit=$exitCode result=$($result | ConvertTo-Json -Depth 8 -Compress))"
    Assert-True -Condition (($calls -join ",") -eq "target:PRNT1111,target:PRNT2222,cleanup:2") -Message "cleanup should run once after every non-destructive target"
    Assert-True -Condition ($result.summary.actionsByCategory.deleted -eq 1) -Message "the public envelope should aggregate one deletion"
    Assert-True -Condition ($result.results[-1].actions[0].before.PSObject.Properties.Name.Count -eq 5) -Message "the public action should retain the complete removed asset set"
    Assert-True -Condition ($null -eq $result.results[-1].actions[0].after) -Message "the public deletion action should have after=null"

    Write-Output "All $passed live-duplicate-cleanup assertions passed."
}
finally {
    $resolvedTempRoot = [IO.Path]::GetFullPath($tempRoot)
    $resolvedSystemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolvedTempRoot.StartsWith($resolvedSystemTemp, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
