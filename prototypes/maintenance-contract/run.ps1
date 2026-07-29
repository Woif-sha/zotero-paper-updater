[CmdletBinding()]
param(
    [ValidateSet("unchanged", "modified", "mixed", "failed")]
    [string]$Scenario,

    [ValidateSet("all", "itemKey", "path")]
    [string]$Scope = "all"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "ContractPrototype.psm1") -Force

function Show-Frame {
    param(
        [string]$CurrentScenario,
        [string]$CurrentScope
    )

    Clear-Host
    $bold = "`e[1m"
    $dim = "`e[2m"
    $reset = "`e[0m"
    $result = New-PrototypeMaintenanceResult -Scenario $CurrentScenario -ScopeMode $CurrentScope

    Write-Host "${bold}Question${reset}"
    Write-Host "Does one stable JSON envelope remain clear when scope, mutations, and unresolved outcomes combine?"
    Write-Host ""
    Write-Host "${bold}Current state${reset}"
    Write-Host "${dim}scenario=$CurrentScenario scope=$CurrentScope${reset}"
    $result | ConvertTo-Json -Depth 12
    Write-Host ""
    Write-Host "${bold}Scenarios${reset}"
    Write-Host "[1] unchanged  [2] modified  [3] mixed actions + unresolved  [4] failed"
    Write-Host "${bold}Scope${reset}"
    Write-Host "[a] all library  [k] item key  [p] path  [q] quit"
}

if ($PSBoundParameters.ContainsKey("Scenario")) {
    New-PrototypeMaintenanceResult -Scenario $Scenario -ScopeMode $Scope |
        ConvertTo-Json -Depth 12
    exit 0
}

$currentScenario = "unchanged"
$currentScope = $Scope

while ($true) {
    Show-Frame -CurrentScenario $currentScenario -CurrentScope $currentScope
    $choice = (Read-Host "Choose").Trim().ToLowerInvariant()

    switch ($choice) {
        "1" { $currentScenario = "unchanged" }
        "2" { $currentScenario = "modified" }
        "3" { $currentScenario = "mixed" }
        "4" { $currentScenario = "failed" }
        "a" { $currentScope = "all" }
        "k" { $currentScope = "itemKey" }
        "p" { $currentScope = "path" }
        "q" { exit 0 }
    }
}
