Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot "ZoteroPaperUpdater.Common.psm1") -DisableNameChecking

function Get-RequiredObjectProperty {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        throw "Zotero item is missing required property '$Name'."
    }
    $property.Value
}

function Get-ZoteroItemKey {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Item
    )

    [string](Get-RequiredObjectProperty -InputObject $Item -Name "key")
}

function Get-ZoteroItemData {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Item
    )

    Get-RequiredObjectProperty -InputObject $Item -Name "data"
}

function Get-LivePdfAttachmentRelation {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Items
    )

    $itemsByKey = @{}
    foreach ($item in $Items) {
        $key = Get-ZoteroItemKey -Item $item
        if ($itemsByKey.ContainsKey($key)) {
            $itemsByKey[$key] = @($itemsByKey[$key]) + $item
        }
        else {
            $itemsByKey[$key] = @($item)
        }
    }

    $relations = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $Items) {
        $data = Get-ZoteroItemData -Item $item
        if ([string]$data.itemType -ne "attachment" -or
            [string]$data.contentType -ne "application/pdf") {
            continue
        }

        $parentKey = [string]$data.parentItem
        $parentCandidates = if ($itemsByKey.ContainsKey($parentKey)) {
            @($itemsByKey[$parentKey])
        }
        else {
            @()
        }
        $parentMatches = @(
            $parentCandidates |
                Where-Object { [string](Get-ZoteroItemData -Item $_).itemType -ne "attachment" }
        )
        if ($parentMatches.Count -ne 1) {
            continue
        }

        $relations.Add([pscustomobject][ordered]@{
            parentItemKey = $parentKey
            attachmentKey = Get-ZoteroItemKey -Item $item
        })
    }
    $relations.ToArray()
}

function Test-ZoteroItemKey {
    param(
        [AllowNull()]
        [string]$Key
    )

    $Key -cmatch "^[23456789ABCDEFGHIJKLMNPQRSTUVWXYZ]{8}$"
}

function Get-StoragePdfEvidence {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Scope,

        [Parameter(Mandatory = $true)]
        [string]$AttachmentKey
    )

    if (-not (Test-ZoteroItemKey -Key $AttachmentKey)) {
        return [pscustomobject]@{
            pdf = $null
            issueCode = "association_ambiguous"
        }
    }

    $storageRoot = [System.IO.Path]::GetFullPath((Join-Path $Scope.zoteroDataDir "storage"))
    $storageDirectory = [System.IO.Path]::GetFullPath((Join-Path $storageRoot $AttachmentKey))
    if (-not (Test-PathWithinRoot -Path $storageDirectory -Root $storageRoot)) {
        return [pscustomobject]@{
            pdf = $null
            issueCode = "association_ambiguous"
        }
    }
    if (-not (Test-PathWithoutReparsePoint -Path $storageRoot) -or
        -not (Test-PathWithoutReparsePoint -Path $storageDirectory)) {
        return [pscustomobject]@{
            pdf = $null
            issueCode = "path_reparse_point"
        }
    }

    $storageEntries = @(
        if (Test-Path -LiteralPath $storageDirectory -PathType Container) {
            Get-ChildItem -LiteralPath $storageDirectory -Force -ErrorAction Stop
        }
    )
    if (@(
        $storageEntries |
            Where-Object {
                ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
            }
    ).Count -gt 0) {
        return [pscustomobject]@{
            pdf = $null
            issueCode = "path_reparse_point"
        }
    }
    $storagePdfs = @(
        $storageEntries |
            Where-Object { -not $_.PSIsContainer -and $_.Extension -ieq ".pdf" }
    )
    if ($storagePdfs.Count -ne 1) {
        return [pscustomobject]@{
            pdf = $null
            issueCode = "association_ambiguous"
        }
    }
    if (-not (Test-PathWithoutReparsePoint -Path $storagePdfs[0].FullName)) {
        return [pscustomobject]@{
            pdf = $null
            issueCode = "path_reparse_point"
        }
    }
    [pscustomobject]@{
        pdf = $storagePdfs[0]
        issueCode = $null
    }
}

function New-ResolutionIssue {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Constructs an in-memory issue and does not change external state."
    )]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Code,

        [Parameter(Mandatory = $true)]
        [object]$Target,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [object[]]$Evidence = @()
    )

    [pscustomobject][ordered]@{
        severity = "error"
        code = $Code
        target = $Target
        message = $Message
        evidence = @($Evidence)
    }
}

function New-BlockedResolution {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Constructs an in-memory resolution and does not change external state."
    )]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Target,

        [Parameter(Mandatory = $true)]
        [string]$Code,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [object[]]$Evidence = @()
    )

    [pscustomobject][ordered]@{
        target = $Target
        issue = New-ResolutionIssue -Code $Code -Target $Target -Message $Message -Evidence $Evidence
    }
}

function New-ResolvedTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Constructs an in-memory resolution and does not change external state."
    )]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Target
    )

    [pscustomobject][ordered]@{
        target = $Target
        issue = $null
    }
}

function New-MaintenanceTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Constructs an in-memory target and does not change external state."
    )]
    param(
        [AllowNull()]
        [string]$ParentItemKey,

        [AllowNull()]
        [string]$AttachmentKey,

        [AllowNull()]
        [string]$Path,

        [AllowNull()]
        [string]$StoragePath
    )

    [pscustomobject][ordered]@{
        parentItemKey = $ParentItemKey
        attachmentKey = $AttachmentKey
        path = $Path
        storagePath = $StoragePath
    }
}

function ConvertTo-EvidenceHashIndex {
    param(
        [object[]]$Evidence = @()
    )

    $index = @{}
    foreach ($entry in $Evidence) {
        $hash = [string]$entry.hash
        if ([string]::IsNullOrWhiteSpace($hash)) {
            continue
        }
        if ($index.ContainsKey($hash)) {
            $index[$hash] = @($index[$hash]) + $entry
        }
        else {
            $index[$hash] = @($entry)
        }
    }
    $index
}

function Get-EvidenceByHash {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Index,

        [AllowNull()]
        [string]$Hash
    )

    if ([string]::IsNullOrWhiteSpace($Hash) -or -not $Index.ContainsKey($Hash)) {
        return @()
    }
    @($Index[$Hash])
}

function Get-ParentRelationGroup {
    param(
        [object[]]$Relation = @()
    )

    $parentOrder = [System.Collections.Generic.List[string]]::new()
    $relationsByParent = @{}
    foreach ($entry in $Relation) {
        $parentKey = [string]$entry.parentItemKey
        if (-not $relationsByParent.ContainsKey($parentKey)) {
            $parentOrder.Add($parentKey)
            $relationsByParent[$parentKey] = [System.Collections.Generic.List[object]]::new()
        }
        $relationsByParent[$parentKey].Add($entry)
    }
    foreach ($parentKey in $parentOrder) {
        [pscustomobject]@{
            name = $parentKey
            group = $relationsByParent[$parentKey].ToArray()
        }
    }
}

function Get-MaintenanceEvidenceIndex {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Scope,

        [Parameter(Mandatory = $true)]
        [object[]]$Items
    )

    $paperRootSafe = Test-PathWithoutReparsePoint -Path $Scope.paperRoot
    $paperRootEntries = @(
        if ($paperRootSafe -and (Test-Path -LiteralPath $Scope.paperRoot -PathType Container)) {
            Get-ChildItem -LiteralPath $Scope.paperRoot -Recurse -Force -ErrorAction Stop
        }
    )
    if (@(
        $paperRootEntries |
            Where-Object {
                ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
            }
    ).Count -gt 0) {
        $paperRootSafe = $false
    }
    $localFiles = @(
        if ($paperRootSafe) {
            $paperRootEntries |
                Where-Object { -not $_.PSIsContainer -and $_.Extension -ieq ".pdf" }
        }
    )
    $localEvidence = @(
        foreach ($file in $localFiles) {
            [pscustomobject][ordered]@{
                path = $file.FullName
                hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
            }
        }
    )
    $storageEvidence = @(
        foreach ($relation in @(Get-LivePdfAttachmentRelation -Items $Items)) {
            $storageEvidence = Get-StoragePdfEvidence `
                -Scope $Scope `
                -AttachmentKey $relation.attachmentKey
            $storagePdf = $storageEvidence.pdf
            [pscustomobject][ordered]@{
                parentItemKey = $relation.parentItemKey
                attachmentKey = $relation.attachmentKey
                issueCode = $storageEvidence.issueCode
                storagePath = if ($null -eq $storagePdf) { $null } else { $storagePdf.FullName }
                storageName = if ($null -eq $storagePdf) { $null } else { $storagePdf.Name }
                hash = if ($null -eq $storagePdf) {
                    $null
                }
                else {
                    (Get-FileHash -LiteralPath $storagePdf.FullName -Algorithm SHA256).Hash
                }
            }
        }
    )

    [pscustomobject][ordered]@{
        paperRootSafe = $paperRootSafe
        local = $localEvidence
        storage = $storageEvidence
        localByHash = ConvertTo-EvidenceHashIndex -Evidence $localEvidence
        storageByHash = ConvertTo-EvidenceHashIndex -Evidence $storageEvidence
    }
}

function Resolve-StorageRelation {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Scope,

        [Parameter(Mandatory = $true)]
        [object]$Relation,

        [Parameter(Mandatory = $true)]
        [object]$EvidenceIndex
    )

    $baseTarget = New-MaintenanceTarget `
        -ParentItemKey $Relation.parentItemKey `
        -AttachmentKey $Relation.attachmentKey
    if (-not $EvidenceIndex.paperRootSafe) {
        return New-BlockedResolution `
            -Target $baseTarget `
            -Code "path_reparse_point" `
            -Message "PaperRoot or one of its descendants contains a reparse point."
    }
    if ([string]::IsNullOrWhiteSpace([string]$Relation.storagePath)) {
        $issueCode = if ([string]::IsNullOrWhiteSpace([string]$Relation.issueCode)) {
            "association_ambiguous"
        }
        else {
            [string]$Relation.issueCode
        }
        return New-BlockedResolution `
            -Target $baseTarget `
            -Code $issueCode `
            -Message "The live Zotero attachment does not have exactly one storage PDF." `
            -Evidence @("attachmentKey:$($Relation.attachmentKey)")
    }

    $sameStorageHash = @(
        Get-EvidenceByHash -Index $EvidenceIndex.storageByHash -Hash $Relation.hash
    )
    if ($sameStorageHash.Count -gt 1) {
        return New-BlockedResolution `
            -Target $baseTarget `
            -Code "association_ambiguous" `
            -Message "The storage PDF hash belongs to more than one live Zotero attachment." `
            -Evidence @($sameStorageHash | ForEach-Object { "attachmentKey:$($_.attachmentKey)" })
    }

    $localMatches = @(
        Get-EvidenceByHash -Index $EvidenceIndex.localByHash -Hash $Relation.hash
    )
    if ($localMatches.Count -gt 1) {
        return New-BlockedResolution `
            -Target $baseTarget `
            -Code "association_ambiguous" `
            -Message "More than one managed local PDF has the attachment's SHA-256." `
            -Evidence @($localMatches | ForEach-Object { "path:$($_.path)" })
    }
    if ($localMatches.Count -eq 1) {
        return New-ResolvedTarget -Target (New-MaintenanceTarget `
            -ParentItemKey $Relation.parentItemKey `
            -AttachmentKey $Relation.attachmentKey `
            -Path $localMatches[0].path `
            -StoragePath $Relation.storagePath)
    }

    $expectedPath = Join-Path $Scope.paperRoot $Relation.storageName
    $expectedTarget = New-MaintenanceTarget `
        -ParentItemKey $Relation.parentItemKey `
        -AttachmentKey $Relation.attachmentKey `
        -Path $expectedPath
    if (Test-Path -LiteralPath $expectedPath -PathType Leaf) {
        $conflictingHash = (Get-FileHash -LiteralPath $expectedPath -Algorithm SHA256).Hash
        return New-BlockedResolution `
            -Target $expectedTarget `
            -Code "hash_conflict" `
            -Message "The managed canonical path contains different bytes from Zotero storage." `
            -Evidence @("storageSha256:$($Relation.hash)", "localSha256:$conflictingHash")
    }

    New-BlockedResolution `
        -Target $expectedTarget `
        -Code "missing_local_copy" `
        -Message "No managed local PDF has the live Zotero storage PDF's SHA-256." `
        -Evidence @("storageSha256:$($Relation.hash)")
}

function Resolve-ItemKeyMaintenanceTarget {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Scope,

        [Parameter(Mandatory = $true)]
        [object[]]$Items,

        [Parameter(Mandatory = $true)]
        [object]$EvidenceIndex
    )

    $selectorTarget = New-MaintenanceTarget -ParentItemKey ([string]$Scope.selector)
    $selectedItems = @($Items | Where-Object { (Get-ZoteroItemKey -Item $_) -ceq $Scope.selector })
    if ($selectedItems.Count -ne 1) {
        return New-BlockedResolution `
            -Target $selectorTarget `
            -Code "association_not_found" `
            -Message "The ItemKey did not resolve to one live Zotero item."
    }

    $selectedData = Get-ZoteroItemData -Item $selectedItems[0]
    if ([string]$selectedData.itemType -eq "attachment") {
        $selectorTarget = New-MaintenanceTarget `
            -ParentItemKey ([string]$selectedData.parentItem) `
            -AttachmentKey ([string]$Scope.selector)
        if ([string]$selectedData.contentType -ne "application/pdf") {
            return New-BlockedResolution `
                -Target $selectorTarget `
                -Code "association_not_found" `
                -Message "The selected Zotero attachment is not a PDF."
        }
        $relations = @($EvidenceIndex.storage | Where-Object { $_.attachmentKey -ceq $Scope.selector })
    }
    else {
        $relations = @($EvidenceIndex.storage | Where-Object { $_.parentItemKey -ceq $Scope.selector })
    }

    if ($relations.Count -eq 0) {
        return New-BlockedResolution `
            -Target $selectorTarget `
            -Code "association_not_found" `
            -Message "The selected Zotero item has no uniquely related live PDF attachment."
    }
    if ($relations.Count -gt 1) {
        return New-BlockedResolution `
            -Target $selectorTarget `
            -Code "association_ambiguous" `
            -Message "The selected Zotero item has more than one related PDF attachment." `
            -Evidence @($relations | ForEach-Object { "attachmentKey:$($_.attachmentKey)" })
    }

    Resolve-StorageRelation -Scope $Scope -Relation $relations[0] -EvidenceIndex $EvidenceIndex
}

function Resolve-PathMaintenanceTarget {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Scope,

        [Parameter(Mandatory = $true)]
        [object]$EvidenceIndex
    )

    $targetPath = [System.IO.Path]::GetFullPath([string]$Scope.selector)
    $pathOnlyTarget = New-MaintenanceTarget -Path $targetPath
    if ([System.IO.Path]::GetExtension($targetPath) -ine ".pdf") {
        return New-BlockedResolution `
            -Target $pathOnlyTarget `
            -Code "association_not_found" `
            -Message "The selected path is not a PDF."
    }
    if (-not (Test-PathWithinRoot -Path $targetPath -Root $Scope.paperRoot)) {
        return New-BlockedResolution `
            -Target $pathOnlyTarget `
            -Code "path_outside_paper_root" `
            -Message "The selected path is outside PaperRoot."
    }
    if (-not $EvidenceIndex.paperRootSafe -or
        -not (Test-PathWithoutReparsePoint -Path $targetPath)) {
        return New-BlockedResolution `
            -Target $pathOnlyTarget `
            -Code "path_reparse_point" `
            -Message "The selected path chain contains a reparse point."
    }
    if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
        return New-BlockedResolution `
            -Target $pathOnlyTarget `
            -Code "association_not_found" `
            -Message "The selected local PDF does not exist."
    }

    $localHash = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash
    $pathMatches = @(Get-EvidenceByHash -Index $EvidenceIndex.storageByHash -Hash $localHash)
    if ($pathMatches.Count -eq 0) {
        return New-BlockedResolution `
            -Target $pathOnlyTarget `
            -Code "association_not_found" `
            -Message "No live Zotero storage PDF has the selected file's SHA-256." `
            -Evidence @("sha256:$localHash")
    }
    if ($pathMatches.Count -gt 1) {
        return New-BlockedResolution `
            -Target $pathOnlyTarget `
            -Code "association_ambiguous" `
            -Message "More than one live Zotero attachment has the selected file's SHA-256." `
            -Evidence @($pathMatches | ForEach-Object { "attachmentKey:$($_.attachmentKey)" })
    }

    $localMatches = @(
        Get-EvidenceByHash -Index $EvidenceIndex.localByHash -Hash $localHash
    )
    $selectedLocalIsUnique = $localMatches.Count -eq 1 -and
        [System.IO.Path]::GetFullPath([string]$localMatches[0].path).Equals(
            $targetPath,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    if (-not $selectedLocalIsUnique) {
        return New-BlockedResolution `
            -Target $pathOnlyTarget `
            -Code "association_ambiguous" `
            -Message "The selected SHA-256 does not belong to exactly one managed local PDF at the selected path." `
            -Evidence @($localMatches | ForEach-Object { "path:$($_.path)" })
    }

    $match = $pathMatches[0]
    New-ResolvedTarget -Target (New-MaintenanceTarget `
        -ParentItemKey $match.parentItemKey `
        -AttachmentKey $match.attachmentKey `
        -Path $targetPath `
        -StoragePath $match.storagePath)
}

function Resolve-AllMaintenanceTarget {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Scope,

        [Parameter(Mandatory = $true)]
        [object]$EvidenceIndex
    )

    if (-not $EvidenceIndex.paperRootSafe) {
        return New-BlockedResolution `
            -Target (New-MaintenanceTarget -Path $Scope.paperRoot) `
            -Code "path_reparse_point" `
            -Message "PaperRoot or one of its descendants contains a reparse point."
    }

    $resolutions = [System.Collections.Generic.List[object]]::new()
    $accountedLocalPaths = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($parentGroup in @(Get-ParentRelationGroup -Relation $EvidenceIndex.storage)) {
        $relations = @($parentGroup.Group)
        if ($relations.Count -gt 1) {
            $target = New-MaintenanceTarget -ParentItemKey ([string]$parentGroup.Name)
            $resolutions.Add((New-BlockedResolution `
                -Target $target `
                -Code "association_ambiguous" `
                -Message "The live Zotero parent has more than one PDF attachment." `
                -Evidence @($relations | ForEach-Object { "attachmentKey:$($_.attachmentKey)" })))
            continue
        }

        $resolution = Resolve-StorageRelation `
            -Scope $Scope `
            -Relation $relations[0] `
            -EvidenceIndex $EvidenceIndex
        $resolutions.Add($resolution)
        if (-not [string]::IsNullOrWhiteSpace([string]$resolution.target.path)) {
            $null = $accountedLocalPaths.Add([string]$resolution.target.path)
        }
    }

    foreach ($local in $EvidenceIndex.local) {
        if ($accountedLocalPaths.Contains([string]$local.path)) {
            continue
        }
        $storageMatches = @(Get-EvidenceByHash -Index $EvidenceIndex.storageByHash -Hash $local.hash)
        if ($storageMatches.Count -gt 0) {
            continue
        }
        $target = New-MaintenanceTarget -Path $local.path
        $resolutions.Add((New-BlockedResolution `
            -Target $target `
            -Code "association_not_found" `
            -Message "The managed local PDF has no byte-identical live Zotero attachment." `
            -Evidence @("sha256:$($local.hash)")))
    }
    $resolutions.ToArray()
}

Export-ModuleMember -Function `
    Get-MaintenanceEvidenceIndex, `
    Resolve-ItemKeyMaintenanceTarget, `
    Resolve-PathMaintenanceTarget, `
    Resolve-AllMaintenanceTarget
