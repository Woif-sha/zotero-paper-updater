[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptRoot = Join-Path $repoRoot "scripts"
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

$publicScripts = @(Get-ChildItem -LiteralPath $scriptRoot -File -Filter "*.ps1")
Assert-True `
    -Condition ($publicScripts.Count -eq 1 -and $publicScripts[0].Name -eq "maintain-library.ps1") `
    -Message "maintain-library.ps1 must be the only public PowerShell command"

$entryText = [IO.File]::ReadAllText((Join-Path $scriptRoot "maintain-library.ps1"))
Assert-True `
    -Condition (-not $entryText.Contains('"-adaptermodulepath"') -and
        -not $entryText.Contains('$parsedArguments.AdapterModulePath')) `
    -Message "the public command must not expose adapter injection"

$skillPath = Join-Path $repoRoot "SKILL.md"
$skillLines = @(Get-Content -LiteralPath $skillPath)
$skillText = $skillLines -join [Environment]::NewLine
Assert-True -Condition ($skillLines.Count -le 90) -Message "SKILL.md must stay within 90 lines"
Assert-True `
    -Condition $skillText.Contains("workflows/maintain-library.md") `
    -Message "SKILL.md must route maintenance to the sole workflow"
$workflowLinks = @(
    [regex]::Matches($skillText, 'workflows/[A-Za-z0-9._-]+\.md') |
        ForEach-Object Value |
        Sort-Object -Unique
)
Assert-True `
    -Condition ($workflowLinks.Count -eq 1 -and
        $workflowLinks[0] -eq "workflows/maintain-library.md") `
    -Message "SKILL.md must route to exactly one workflow"
Assert-True `
    -Condition ($skillText -match "do not use.*reading.*analysis.*comparison.*note authoring") `
    -Message "the description must make the adjacent content-task boundary explicit"

Assert-True `
    -Condition (Test-Path -LiteralPath (Join-Path $repoRoot "workflows\maintain-library.md") -PathType Leaf) `
    -Message "the maintenance workflow must be the single detailed rule source"
Assert-True `
    -Condition (-not (Test-Path -LiteralPath (Join-Path $repoRoot "references\workflow.md"))) `
    -Message "the legacy workflow rule source must be removed"
Assert-True `
    -Condition (-not (Test-Path -LiteralPath (Join-Path $repoRoot "assets\paper-note-template.md"))) `
    -Message "the out-of-scope paper note template must be removed"

$evalDocument = Get-Content -LiteralPath (Join-Path $repoRoot "evals\evals.json") -Raw |
    ConvertFrom-Json
Assert-True -Condition (@($evalDocument.queries).Count -eq 20) -Message "routing evals must contain 20 queries"
Assert-True `
    -Condition (@($evalDocument.queries | Where-Object shouldTrigger).Count -eq 10) `
    -Message "routing evals must contain 10 maintenance positives"
Assert-True `
    -Condition (@($evalDocument.queries | Where-Object { -not $_.shouldTrigger }).Count -eq 10) `
    -Message "routing evals must contain 10 adjacent negatives"
$queryIds = @($evalDocument.queries.id | Sort-Object -Unique)
$queryTexts = @($evalDocument.queries.query | Sort-Object -Unique)
Assert-True `
    -Condition ($queryIds.Count -eq 20 -and $queryTexts.Count -eq 20) `
    -Message "routing eval IDs and prompts must be unique"
foreach ($pairId in 1..10) {
    $pair = @($evalDocument.queries | Where-Object pairId -eq $pairId)
    Assert-True `
        -Condition ($pair.Count -eq 2 -and
            @($pair | Where-Object shouldTrigger).Count -eq 1 -and
            @($pair | Where-Object { -not $_.shouldTrigger }).Count -eq 1) `
        -Message "routing pair $pairId must contain one positive and one adjacent negative"
}
Assert-True `
    -Condition (@(
        $evalDocument.queries |
            Where-Object {
                $_.shouldTrigger -and
                $_.expectedRoute -ne "workflows/maintain-library.md"
            }
    ).Count -eq 0) `
    -Message "every positive must route to the sole workflow"
Assert-True `
    -Condition (@(
        $evalDocument.queries |
            Where-Object {
                -not $_.shouldTrigger -and
                [string]::IsNullOrWhiteSpace([string]$_.expectedOwner)
            }
    ).Count -eq 0) `
    -Message "every adjacent negative must identify its owning capability"
Assert-True `
    -Condition ([string]$evalDocument.contract -match "proxy" -and
        [string]$evalDocument.contract -match "not.*trigger rate") `
    -Message "routing evals must state that deterministic checks are a proxy, not a model trigger-rate measurement"

Write-Output "All $passed public-surface contract assertions passed."
