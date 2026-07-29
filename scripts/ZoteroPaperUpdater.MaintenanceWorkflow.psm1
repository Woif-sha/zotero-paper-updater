Set-StrictMode -Version Latest

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
    foreach ($command in @("Resolve-MaintenanceTarget", "Invoke-MaintenanceTarget")) {
        if ($command -notin $adapterModule.ExportedCommands.Keys) {
            throw "Adapter module '$AdapterModulePath' does not export '$command'."
        }
    }

    $targets = @(Invoke-AdapterCommand -Module $adapterModule -Command "Resolve-MaintenanceTarget" -Arguments @{
        Scope = $Scope
    })
    $records = [System.Collections.Generic.List[object]]::new()
    $fatalError = $null
    foreach ($target in $targets) {
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

    [pscustomobject][ordered]@{
        records = $records.ToArray()
        fatalError = $fatalError
    }
}

Export-ModuleMember -Function Invoke-PaperMaintenanceWorkflow
