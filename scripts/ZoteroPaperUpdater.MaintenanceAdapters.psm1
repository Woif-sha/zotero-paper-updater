Set-StrictMode -Version Latest

$script:ZoteroApiBase = "http://127.0.0.1:23119/api/users/0"
$script:PageSize = 100

function Get-MaintenanceZoteroItem {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Scope
    )

    $null = $Scope
    $items = [System.Collections.Generic.List[object]]::new()
    $start = 0
    $headers = @{ "Zotero-API-Version" = "3" }
    do {
        $uri = "$($script:ZoteroApiBase)/items?limit=$($script:PageSize)&start=$start"
        $page = @(
            Invoke-RestMethod `
                -Uri $uri `
                -Headers $headers `
                -Method Get `
                -TimeoutSec 10
        )
        foreach ($item in $page) {
            $items.Add($item)
        }
        $start += $page.Count
    } while ($page.Count -eq $script:PageSize)

    $items.ToArray()
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

Export-ModuleMember -Function Get-MaintenanceZoteroItem, Invoke-MaintenanceTarget
