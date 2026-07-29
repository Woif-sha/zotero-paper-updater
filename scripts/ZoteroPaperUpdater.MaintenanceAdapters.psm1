Set-StrictMode -Version Latest

function Resolve-MaintenanceTarget {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Scope
    )

    $null = $Scope
    throw "Live Zotero target resolution is not implemented yet; issue #10 provides this adapter."
}

function Invoke-MaintenanceTarget {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Target,

        [Parameter(Mandatory = $true)]
        [object]$Scope
    )

    $null = $Target
    $null = $Scope
    throw "Live Zotero target maintenance is not implemented yet."
}

Export-ModuleMember -Function Resolve-MaintenanceTarget, Invoke-MaintenanceTarget
