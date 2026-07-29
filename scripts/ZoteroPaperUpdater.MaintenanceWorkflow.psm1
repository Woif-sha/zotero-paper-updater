Set-StrictMode -Version Latest

$targetResolutionPath = Join-Path $PSScriptRoot "ZoteroPaperUpdater.TargetResolution.psm1"
Import-Module -Name $targetResolutionPath -Force -DisableNameChecking

function Invoke-AdapterCommand {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSModuleInfo]$Module,

        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [hashtable]$Arguments
    )

    & $Module {
        param($CommandName, $CommandArguments)
        & $CommandName @CommandArguments
    } $Command $Arguments
}

function Invoke-PaperMaintenanceWorkflow {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Scope,

        [Parameter(Mandatory = $true)]
        [string]$AdapterModulePath
    )

    $adapterModule = Import-Module -Name $AdapterModulePath -Force -PassThru -DisableNameChecking -WarningAction SilentlyContinue
    foreach ($command in @("Get-MaintenanceZoteroItem", "Invoke-MaintenanceTarget")) {
        if ($command -notin $adapterModule.ExportedCommands.Keys) {
            throw "Adapter module '$AdapterModulePath' does not export '$command'."
        }
    }

    $items = @(Invoke-AdapterCommand -Module $adapterModule -Command "Get-MaintenanceZoteroItem" -Arguments @{
        Scope = $Scope
    })
    $evidenceIndex = Get-MaintenanceEvidenceIndex -Scope $Scope -Items $items
    if ($Scope.mode -eq "itemKey") {
        $resolutions = @(
            Resolve-ItemKeyMaintenanceTarget `
                -Scope $Scope `
                -Items $items `
                -EvidenceIndex $evidenceIndex
        )
    }
    elseif ($Scope.mode -eq "path") {
        $resolutions = @(Resolve-PathMaintenanceTarget -Scope $Scope -EvidenceIndex $evidenceIndex)
    }
    else {
        $resolutions = @(Resolve-AllMaintenanceTarget -Scope $Scope -EvidenceIndex $evidenceIndex)
    }

    $records = [System.Collections.Generic.List[object]]::new()
    $fatalError = $null
    foreach ($resolution in $resolutions) {
        $target = $resolution.target
        if ($null -ne $resolution.issue) {
            $records.Add([pscustomobject][ordered]@{
                target = $target
                adapterResult = [pscustomobject][ordered]@{
                    status = "failed"
                    actions = @()
                    issues = @($resolution.issue)
                }
            })
            continue
        }
        try {
            $adapterResult = Invoke-AdapterCommand -Module $adapterModule -Command "Invoke-MaintenanceTarget" -Arguments @{
                Target = $target
                Scope = $Scope
            }
            $records.Add([pscustomobject][ordered]@{
                target = $target
                adapterResult = $adapterResult
            })
        }
        catch {
            $fatalError = $_
            break
        }
    }

    if ($null -eq $fatalError -and
        "Invoke-MaintenanceCleanup" -in $adapterModule.ExportedCommands.Keys) {
        $blockedResolutionCount = @($resolutions | Where-Object { $null -ne $_.issue }).Count
        $incompleteTargetCount = @(
            $records |
                Where-Object { [string]$_.adapterResult.status -ne "succeeded" }
        ).Count
        if ($blockedResolutionCount -eq 0 -and $incompleteTargetCount -eq 0) {
            try {
                $cleanupResult = Invoke-AdapterCommand `
                    -Module $adapterModule `
                    -Command "Invoke-MaintenanceCleanup" `
                    -Arguments @{
                        Scope = $Scope
                        Targets = @($resolutions | ForEach-Object { $_.target })
                    }
                $cleanupActions = @($cleanupResult.actions)
                $cleanupIssues = @($cleanupResult.issues)
                if ($cleanupActions.Count -gt 0 -or $cleanupIssues.Count -gt 0) {
                    $records.Add([pscustomobject][ordered]@{
                        target = $cleanupResult.target
                        adapterResult = $cleanupResult
                    })
                }
            }
            catch {
                $fatalError = $_
            }
        }
    }

    [pscustomobject][ordered]@{
        records = $records.ToArray()
        fatalError = $fatalError
    }
}

Export-ModuleMember -Function Invoke-PaperMaintenanceWorkflow
