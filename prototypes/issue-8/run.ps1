[CmdletBinding()]
param(
    [ValidateSet(
        "Interactive",
        "All",
        "default-call",
        "item-key-call",
        "path-call",
        "duplicate-cleanup-first-run",
        "duplicate-cleanup-repeat",
        "metadata-not-found",
        "filename-conflict",
        "ambiguous-association",
        "invalid-dual-selector"
    )]
    [string]$Scenario = "Interactive",

    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "CompatibilityPrototype.psm1") -Force

if ($Scenario -eq "All") {
    $all = Get-ValidationScenarios
    if ($Json) {
        $all | ConvertTo-Json -Depth 10
    }
    else {
        $all | Format-List
    }
    exit 0
}

if ($Scenario -ne "Interactive") {
    $state = Get-PrototypeState -ScenarioId $Scenario
    if ($Json) {
        $state | ConvertTo-Json -Depth 10
    }
    else {
        $state | Format-List
    }
    exit 0
}

$scenarios = @(Get-ValidationScenarios)
$selectedIndex = 0

while ($true) {
    Clear-Host
    $state = Get-PrototypeState -ScenarioId $scenarios[$selectedIndex].id
    $policy = $state.policy
    $selected = $state.selectedScenario

    Write-Host "`e[1mPROTOTYPE — migration compatibility and validation`e[0m"
    Write-Host "`e[2mNo Zotero records or files are read or changed.`e[0m"
    Write-Host ""
    Write-Host "`e[1mCompatibility boundary`e[0m"
    Write-Host $policy.compatibilityBoundary
    Write-Host ""
    Write-Host "`e[1mOnly public entry`e[0m"
    Write-Host "  $($policy.publicEntry.script)"
    Write-Host ""
    Write-Host "`e[1mSelected scenario`e[0m"
    Write-Host "  id:          $($selected.id)"
    Write-Host "  invocation:  $($selected.invocation)"
    Write-Host "  fixture:     $($selected.fixture)"
    Write-Host "  status:      $($selected.expected.status)"
    Write-Host "  changed:     $($selected.expected.changed)"
    Write-Host "  exitCode:    $($selected.expected.exitCode)"
    Write-Host "  actions:     $(@($selected.expected.actionCategories) -join ', ')"
    Write-Host "  issues:      $(@($selected.expected.issueCodes) -join ', ')"
    Write-Host ""
    Write-Host "`e[1mInvariants`e[0m"
    foreach ($invariant in $selected.expected.invariants) {
        Write-Host "  - $invariant"
    }
    Write-Host ""
    Write-Host "`e[1mKeys`e[0m  `e[2m[n] next  [p] previous  [i] interface decisions  [j] JSON  [q] quit`e[0m"

    $key = [Console]::ReadKey($true).KeyChar.ToString().ToLowerInvariant()
    switch ($key) {
        "n" { $selectedIndex = ($selectedIndex + 1) % $scenarios.Count }
        "p" { $selectedIndex = ($selectedIndex - 1 + $scenarios.Count) % $scenarios.Count }
        "i" {
            Clear-Host
            $policy | ConvertTo-Json -Depth 10
            Write-Host ""
            Write-Host "`e[2mPress any key to return.`e[0m"
            [Console]::ReadKey($true) | Out-Null
        }
        "j" {
            Clear-Host
            $state | ConvertTo-Json -Depth 10
            Write-Host ""
            Write-Host "`e[2mPress any key to return.`e[0m"
            [Console]::ReadKey($true) | Out-Null
        }
        "q" { break }
    }

    if ($key -eq "q") {
        break
    }
}
