Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot "ZoteroPaperUpdater.Common.psm1") -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "ZoteroPaperUpdater.MetadataEnrichment.psm1") -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "ZoteroPaperUpdater.CrossrefSource.psm1") -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "ZoteroPaperUpdater.ZoteroWriter.psm1") -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "ZoteroPaperUpdater.FileRename.psm1") -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "ZoteroPaperUpdater.DuplicateCleanup.psm1") -DisableNameChecking
Import-Module `
    (Join-Path $PSScriptRoot "ZoteroPaperUpdater.DuplicateCleanupLive.psm1") `
    -DisableNameChecking `
    -Global

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

function Get-MaintenanceTrashItem {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseSingularNouns",
        "",
        Justification = "Returns the current collection of Zotero Trash items."
    )]
    param()

    $items = [Collections.Generic.List[object]]::new()
    $start = 0
    do {
        $uri = "$($script:ZoteroApiBase)/items/trash?limit=$($script:PageSize)&start=$start"
        $page = @(Invoke-ZoteroApiGet -Uri $uri)
        foreach ($item in $page) { $items.Add($item) }
        $start += $page.Count
    } while ($page.Count -eq $script:PageSize)
    $items.ToArray()
}

function Invoke-DefaultCleanupMcp {
    param([Parameter(Mandatory = $true)][object]$Arguments)

    $helperPath = Join-Path $PSScriptRoot "invoke-llm-for-zotero-mcp.ps1"
    $responseJson = & $helperPath `
        -ToolName "zotero_script" `
        -ArgumentsJson ($Arguments | ConvertTo-Json -Depth 30 -Compress)
    $responseJson | ConvertFrom-Json -Depth 100
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

function Merge-MaintenanceStageResult {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$StageResult
    )

    $statuses = @($StageResult | ForEach-Object {
        [string](Get-RequiredPropertyValue -Object $_ -Name "status")
    })
    $status = if ($statuses -contains "failed") {
        "failed"
    }
    elseif ($statuses -contains "partial") {
        "partial"
    }
    else {
        "succeeded"
    }

    [pscustomobject][ordered]@{
        status = $status
        actions = @($StageResult | ForEach-Object {
            @(Get-RequiredPropertyValue -Object $_ -Name "actions")
        })
        issues = @($StageResult | ForEach-Object {
            @(Get-RequiredPropertyValue -Object $_ -Name "issues")
        })
    }
}

function ConvertTo-FileRenameTarget {
    param([Parameter(Mandatory = $true)][object]$Target)

    $localPath = [string](Get-OptionalPropertyValue -Object $Target -Name "path")
    $storagePath = [string](Get-OptionalPropertyValue -Object $Target -Name "storagePath")
    [pscustomobject][ordered]@{
        parentItemKey = Get-RequiredPropertyValue -Object $Target -Name "parentItemKey"
        attachmentKey = Get-RequiredPropertyValue -Object $Target -Name "attachmentKey"
        path = $localPath
        localPdfPaths = if ([string]::IsNullOrWhiteSpace($localPath)) { @() } else { @($localPath) }
        storagePdfPaths = if ([string]::IsNullOrWhiteSpace($storagePath)) { @() } else { @($storagePath) }
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
    $metadataResult = Invoke-MetadataEnrichment `
        -ParentItem $parentSnapshot `
        -Target $Target `
        -QueryAdapter $QueryAdapter `
        -WriteAdapter $writeAdapter
    $renameResult = Invoke-LocalPdfRename `
        -Target (ConvertTo-FileRenameTarget -Target $Target) `
        -PaperRoot ([string](Get-RequiredPropertyValue -Object $Scope -Name "paperRoot")) `
        -StorageRoot (Join-Path `
            ([string](Get-RequiredPropertyValue -Object $Scope -Name "zoteroDataDir")) `
            "storage")
    Merge-MaintenanceStageResult -StageResult @($metadataResult, $renameResult)
}

function Invoke-MaintenanceCleanup {
    param(
        [Parameter(Mandatory = $true)][object]$Scope,
        [Parameter(Mandatory = $true)][object[]]$Targets,
        [scriptblock]$ReadAllItems,
        [scriptblock]$ReadTrashItems,
        [scriptblock]$McpAdapter
    )

    if ($null -eq $ReadAllItems) {
        $ReadAllItems = { param($ReadScope) Get-MaintenanceZoteroItem -Scope $ReadScope }
    }
    if ($null -eq $ReadTrashItems) {
        $ReadTrashItems = { Get-MaintenanceTrashItem }
    }
    if ($null -eq $McpAdapter) {
        $McpAdapter = { param($Arguments) Invoke-DefaultCleanupMcp -Arguments $Arguments }
    }
    $operations = Get-LiveDuplicateCleanupOperationTable `
        -Scope $Scope `
        -ReadAllItems $ReadAllItems `
        -ReadTrashItems $ReadTrashItems `
        -McpAdapter $McpAdapter
    Invoke-MinimalDuplicateCleanup `
        -Scope $Scope `
        -Targets $Targets `
        -Operations $operations
}

Export-ModuleMember -Function `
    Get-MaintenanceZoteroItem, `
    Invoke-MaintenanceTarget, `
    Invoke-MaintenanceCleanup
