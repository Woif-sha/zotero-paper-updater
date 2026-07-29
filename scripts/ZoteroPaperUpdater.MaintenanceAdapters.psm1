Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot "ZoteroPaperUpdater.Common.psm1") -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "ZoteroPaperUpdater.MetadataEnrichment.psm1") -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "ZoteroPaperUpdater.CrossrefSource.psm1") -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "ZoteroPaperUpdater.ZoteroWriter.psm1") -DisableNameChecking

$script:ZoteroApiBase = "http://127.0.0.1:23119/api/users/0"
$script:PageSize = 100
$script:ZoteroApiHeaders = @{ "Zotero-API-Version" = "3" }

function Invoke-ZoteroApiGet {
    param([Parameter(Mandatory = $true)][string]$Uri)

    Invoke-RestMethod `
        -Uri $Uri `
        -Headers $script:ZoteroApiHeaders `
        -Method Get `
        -TimeoutSec 10
}

function Get-MaintenanceZoteroItem {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseSingularNouns",
        "",
        Justification = "Public adapter contract retained by the maintenance workflow."
    )]
    param([Parameter(Mandatory = $true)][object]$Scope)

    $null = $Scope
    $items = [Collections.Generic.List[object]]::new()
    $start = 0
    do {
        $uri = "$($script:ZoteroApiBase)/items?limit=$($script:PageSize)&start=$start"
        $page = @(Invoke-ZoteroApiGet -Uri $uri)
        foreach ($item in $page) {
            $items.Add($item)
        }
        $start += $page.Count
    } while ($page.Count -eq $script:PageSize)
    $items.ToArray()
}

function Get-LiveZoteroParent {
    param([Parameter(Mandatory = $true)][string]$ParentItemKey)

    $encodedKey = [uri]::EscapeDataString($ParentItemKey)
    $item = Invoke-ZoteroApiGet -Uri "$($script:ZoteroApiBase)/items/$encodedKey"
    $data = Get-RequiredPropertyValue -Object $item -Name "data"
    if ([string](Get-RequiredPropertyValue -Object $data -Name "itemType") -eq "attachment") {
        throw "Resolved parent item '$ParentItemKey' is an attachment."
    }
    $item
}

function ConvertTo-MetadataParentSnapshot {
    param([Parameter(Mandatory = $true)][object]$LiveItem)

    $data = Get-RequiredPropertyValue -Object $LiveItem -Name "data"
    [pscustomobject][ordered]@{
        key = [string](Get-RequiredPropertyValue -Object $LiveItem -Name "key")
        version = Get-RequiredPropertyValue -Object $LiveItem -Name "version"
        itemType = [string](Get-RequiredPropertyValue -Object $data -Name "itemType")
        fields = $data
    }
}

function Invoke-MaintenanceTarget {
    param(
        [Parameter(Mandatory = $true)][object]$Target,
        [Parameter(Mandatory = $true)][object]$Scope,
        [scriptblock]$ReadAdapter,
        [scriptblock]$QueryAdapter,
        [scriptblock]$MetadataHttpAdapter,
        [scriptblock]$McpAdapter
    )

    $null = $Scope
    $parentKey = [string](Get-RequiredPropertyValue -Object $Target -Name "parentItemKey")
    if ([string]::IsNullOrWhiteSpace($parentKey)) {
        throw "A resolved maintenance target must identify a parent item."
    }
    if ($null -eq $ReadAdapter) {
        $ReadAdapter = { param($Key) Get-LiveZoteroParent -ParentItemKey $Key }
    }
    if ($null -eq $QueryAdapter) {
        $null = $MetadataHttpAdapter
        $QueryAdapter = {
            param($Query)
            Invoke-CrossrefMetadataQuery -Query $Query -HttpAdapter $MetadataHttpAdapter
        }
    }

    $liveParent = & $ReadAdapter $parentKey
    $parentSnapshot = ConvertTo-MetadataParentSnapshot -LiveItem $liveParent
    $null = $McpAdapter
    $writeAdapter = {
        param($WriteRequest)
        Invoke-ZoteroMetadataWrite `
            -WriteRequest $WriteRequest `
            -BeforeLiveItem $liveParent `
            -ReadAdapter $ReadAdapter `
            -McpAdapter $McpAdapter
    }
    Invoke-MetadataEnrichment `
        -ParentItem $parentSnapshot `
        -Target $Target `
        -QueryAdapter $QueryAdapter `
        -WriteAdapter $writeAdapter
}

Export-ModuleMember -Function Get-MaintenanceZoteroItem, Invoke-MaintenanceTarget
