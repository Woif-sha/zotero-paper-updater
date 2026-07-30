Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "ZoteroPaperUpdater.Common.psm1") -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "ZoteroPaperUpdater.DuplicateIdentity.psm1") -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "ZoteroPaperUpdater.ZoteroWriter.psm1") -DisableNameChecking

function Get-LiveCleanupSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-LiveCleanupItemData {
    param([Parameter(Mandatory = $true)][object]$Item)

    Get-RequiredPropertyValue -Object $Item -Name "data"
}

function Test-LiveFormalFinalAttachment {
    param([Parameter(Mandatory = $true)][object]$AttachmentData)

    $title = ConvertTo-DuplicateText -Value (
        [string](Get-OptionalPropertyValue -Object $AttachmentData -Name "title")
    )
    if ($title -in @("version of record", "published version", "final published version")) {
        return $true
    }
    $extra = [string](Get-OptionalPropertyValue -Object $AttachmentData -Name "extra")
    @($extra -split "\r?\n" | ForEach-Object { $_.Trim().ToLowerInvariant() }) -contains
        "zpu-formal-final: true"
}

function Test-LiveCleanupUserStateEmpty {
    param(
        [Parameter(Mandatory = $true)][object]$Parent,
        [Parameter(Mandatory = $true)][object]$Attachment,
        [Parameter(Mandatory = $true)][object[]]$Items
    )

    foreach ($item in @($Parent, $Attachment)) {
        $data = Get-LiveCleanupItemData -Item $item
        foreach ($name in @("tags", "collections")) {
            $values = Get-OptionalPropertyValue -Object $data -Name $name
            if ($null -ne $values -and @($values).Count -gt 0) {
                return $false
            }
        }
        $relations = Get-OptionalPropertyValue -Object $data -Name "relations"
        $relationNames = @(
            if ($null -ne $relations) {
                $relations.PSObject.Properties | ForEach-Object { $_.Name }
            }
        )
        if ($relationNames.Count -gt 0) {
            return $false
        }
    }
    $parentKey = [string](Get-RequiredPropertyValue -Object $Parent -Name "key")
    $attachmentKey = [string](Get-RequiredPropertyValue -Object $Attachment -Name "key")
    $nonAssetChildren = @(
        $Items | Where-Object {
            $childData = Get-LiveCleanupItemData -Item $_
            $childParent = [string](Get-OptionalPropertyValue -Object $childData -Name "parentItem")
            $childKey = [string](Get-RequiredPropertyValue -Object $_ -Name "key")
            $childParent -in @($parentKey, $attachmentKey) -and $childKey -cne $attachmentKey
        }
    )
    $nonAssetChildren.Count -eq 0
}

function Find-LiveCleanupCache {
    param(
        [Parameter(Mandatory = $true)][object]$Scope,
        [Parameter(Mandatory = $true)][string]$ParentKey,
        [Parameter(Mandatory = $true)][string]$AttachmentKey
    )

    $cacheRoot = Join-Path $Scope.zoteroDataDir "llm-for-zotero-mineru"
    if (-not (Test-Path -LiteralPath $cacheRoot -PathType Container)) { return $null }
    $cacheMatches = @(
        Get-ChildItem -LiteralPath $cacheRoot -Recurse -File -Filter "_llm_source.json" |
            ForEach-Object {
                $sourcePath = $_.FullName
                try {
                    $source = Get-Content -LiteralPath $sourcePath -Raw | ConvertFrom-Json -Depth 20
                    if ([string](Get-OptionalPropertyValue -Object $source -Name "kind") -ceq
                        "llm-for-zotero/mineru-cache-source" -and
                        [int](Get-OptionalPropertyValue -Object $source -Name "version") -eq 2 -and
                        [string](Get-OptionalPropertyValue -Object $source -Name "parentItemKey") -ceq $ParentKey -and
                        [string](Get-OptionalPropertyValue -Object $source -Name "attachmentKey") -ceq $AttachmentKey) {
                        [pscustomobject]@{
                            source = $source
                            directory = Split-Path -Parent $sourcePath
                        }
                    }
                }
                catch {
                    $exception = [IO.InvalidDataException]::new(
                        "MinerU provenance cannot be read: $sourcePath`: $($_.Exception.Message)",
                        $_.Exception
                    )
                    $exception.Data["ZpuIssueCode"] = "cache_provenance_invalid"
                    throw $exception
                }
            }
    )
    if ($cacheMatches.Count -ne 1) { return $null }
    $health = Test-MineruCacheHealth -CacheDirectory $cacheMatches[0].directory
    if (@($health.issues | Where-Object { $_.severity -eq "error" }).Count -gt 0) { return $null }
    [pscustomobject][ordered]@{
        path = [IO.Path]::GetFullPath($cacheMatches[0].directory)
        fullMdSha256 = Get-LiveCleanupSha256 -Path $health.fullMdPath
        healthy = $true
        complete = $true
        parsedAt = [string](Get-OptionalPropertyValue -Object $cacheMatches[0].source -Name "parsedAt")
        attachmentKey = $AttachmentKey
        parentItemKey = $ParentKey
    }
}

function Get-LiveCleanupAssetEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][object[]]$ExpectedEvidence
    )

    $results = [Collections.Generic.List[object]]::new()
    foreach ($descriptor in $ExpectedEvidence) {
        $kind = [string]$descriptor.kind
        $value = [Management.Automation.PSSerializer]::Deserialize(
            [Management.Automation.PSSerializer]::Serialize($descriptor.value, 20)
        )
        try {
            $path = [IO.Path]::GetFullPath([string]$value.path)
            Assert-PathChainHasNoReparsePoint -Path $path
        }
        catch {
            throw (New-ZpuTypedException `
                -Code "cleanup_drift_path" `
                -Message $_.Exception.Message)
        }
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }
        if ($kind -eq "storage") {
            if (-not (Test-Path -LiteralPath $path -PathType Container)) {
                throw (New-ZpuTypedException `
                    -Code "cleanup_drift_path" `
                    -Message "Cleanup storage path is not a directory: $path")
            }
            $pdfPath = [string](Get-OptionalPropertyValue -Object $value -Name "pdfPath")
            try {
                if ([string]::IsNullOrWhiteSpace($pdfPath)) {
                    throw "Cleanup storage PDF path is empty."
                }
                $pdfPath = [IO.Path]::GetFullPath($pdfPath)
                Assert-PathChainHasNoReparsePoint -Path $pdfPath
                if (-not (Test-PathWithinRoot -Path $pdfPath -Root $path) -or
                    -not (Test-Path -LiteralPath $pdfPath -PathType Leaf)) {
                    throw "Cleanup storage PDF is missing or outside its fixed storage directory."
                }
            }
            catch {
                throw (New-ZpuTypedException `
                    -Code "cleanup_drift_path" `
                    -Message $_.Exception.Message)
            }
            $value.sha256 = Get-LiveCleanupSha256 -Path $pdfPath
        }
        elseif ($kind -eq "local") {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw (New-ZpuTypedException `
                    -Code "cleanup_drift_path" `
                    -Message "Cleanup local PDF path is not a file: $path")
            }
            $value.sha256 = Get-LiveCleanupSha256 -Path $path
        }
        elseif ($kind -eq "cache") {
            $cache = Find-LiveCleanupCache `
                -Scope $Plan.scope `
                -ParentKey ([string]$value.parentItemKey) `
                -AttachmentKey ([string]$value.attachmentKey)
            if ($null -eq $cache -or
                -not [string]::Equals(
                    [IO.Path]::GetFullPath([string]$cache.path),
                    $path,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                throw (New-ZpuTypedException `
                    -Code "cleanup_drift_provenance" `
                    -Message "Cleanup MinerU provenance no longer resolves to the fixed cache path.")
            }
            $value.fullMdSha256 = $cache.fullMdSha256
            $value.healthy = $cache.healthy
        }
        else {
            throw "Unsupported cleanup asset kind '$kind'."
        }
        $results.Add([pscustomobject][ordered]@{
            side = [string]$descriptor.side
            kind = $kind
            value = $value
        })
    }
    $results.ToArray()
}

function Find-LiveCleanupLocalPdf {
    param(
        [Parameter(Mandatory = $true)][object]$Scope,
        [Parameter(Mandatory = $true)][string]$StorageHash
    )

    $localMatches = @(
        Get-ChildItem -LiteralPath $Scope.paperRoot -Recurse -File -Filter "*.pdf" |
            Where-Object { (Get-LiveCleanupSha256 -Path $_.FullName) -ceq $StorageHash }
    )
    if ($localMatches.Count -ne 1) { return $null }
    [pscustomobject][ordered]@{
        path = [IO.Path]::GetFullPath($localMatches[0].FullName)
        sha256 = $StorageHash
    }
}

function ConvertTo-LiveCleanupSide {
    param(
        [Parameter(Mandatory = $true)][object]$Scope,
        [Parameter(Mandatory = $true)][object]$Parent,
        [Parameter(Mandatory = $true)][object]$Attachment,
        [Parameter(Mandatory = $true)][object[]]$Items
    )

    $parentKey = [string](Get-RequiredPropertyValue -Object $Parent -Name "key")
    $attachmentKey = [string](Get-RequiredPropertyValue -Object $Attachment -Name "key")
    $parentData = Get-LiveCleanupItemData -Item $Parent
    $attachmentData = Get-LiveCleanupItemData -Item $Attachment
    $storageDirectory = Join-Path $Scope.zoteroDataDir "storage\$attachmentKey"
    $storagePdfs = @(
        if (Test-Path -LiteralPath $storageDirectory -PathType Container) {
            Get-ChildItem -LiteralPath $storageDirectory -File |
                Where-Object { $_.Extension -ieq ".pdf" }
        }
    )
    if ($storagePdfs.Count -ne 1) { return $null }
    $storageHash = Get-LiveCleanupSha256 -Path $storagePdfs[0].FullName
    $local = Find-LiveCleanupLocalPdf -Scope $Scope -StorageHash $storageHash
    $cache = Find-LiveCleanupCache `
        -Scope $Scope `
        -ParentKey $parentKey `
        -AttachmentKey $attachmentKey
    if ($null -eq $local -or $null -eq $cache) { return $null }
    $childKeys = @(
        $Items | Where-Object {
            [string](Get-OptionalPropertyValue -Object (Get-LiveCleanupItemData -Item $_) -Name "parentItem") -in
                @($parentKey, $attachmentKey)
        } | ForEach-Object { [string](Get-RequiredPropertyValue -Object $_ -Name "key") } |
            Sort-Object
    )
    $childItems = @(
        $Items | Where-Object {
            [string](Get-OptionalPropertyValue -Object (Get-LiveCleanupItemData -Item $_) -Name "parentItem") -in
                @($parentKey, $attachmentKey)
        }
    )
    $notes = @(
        $childItems | Where-Object {
            [string](Get-OptionalPropertyValue -Object (Get-LiveCleanupItemData -Item $_) -Name "itemType") -eq "note"
        } | ForEach-Object { [string]$_.key }
    )
    $annotations = @(
        $childItems | Where-Object {
            [string](Get-OptionalPropertyValue -Object (Get-LiveCleanupItemData -Item $_) -Name "itemType") -eq "annotation"
        }
    )
    $unknownChildren = @(
        $childItems | Where-Object {
            $data = Get-LiveCleanupItemData -Item $_
            $itemType = [string](Get-OptionalPropertyValue -Object $data -Name "itemType")
            [string]$_.key -cne $attachmentKey -and $itemType -notin @("note", "annotation")
        } | ForEach-Object { [string]$_.key }
    )
    [pscustomobject][ordered]@{
        parent = [pscustomobject][ordered]@{
            key = $parentKey
            version = Get-RequiredPropertyValue -Object $Parent -Name "version"
            doi = [string](Get-OptionalPropertyValue -Object $parentData -Name "DOI")
            title = [string](Get-OptionalPropertyValue -Object $parentData -Name "title")
            creators = @(Get-OptionalPropertyValue -Object $parentData -Name "creators")
            publicationTitle = [string](Get-OptionalPropertyValue -Object $parentData -Name "publicationTitle")
            bookTitle = [string](Get-OptionalPropertyValue -Object $parentData -Name "bookTitle")
            conferenceName = [string](Get-OptionalPropertyValue -Object $parentData -Name "conferenceName")
            publisher = [string](Get-OptionalPropertyValue -Object $parentData -Name "publisher")
            date = [string](Get-OptionalPropertyValue -Object $parentData -Name "date")
            volume = [string](Get-OptionalPropertyValue -Object $parentData -Name "volume")
            issue = [string](Get-OptionalPropertyValue -Object $parentData -Name "issue")
            pages = [string](Get-OptionalPropertyValue -Object $parentData -Name "pages")
            dateAdded = [string](Get-OptionalPropertyValue -Object $parentData -Name "dateAdded")
            relations = Get-OptionalPropertyValue -Object $parentData -Name "relations"
            tags = @(Get-OptionalPropertyValue -Object $parentData -Name "tags")
            collections = @(Get-OptionalPropertyValue -Object $parentData -Name "collections")
            childKeys = $childKeys
            notes = $notes
            unknownChildren = $unknownChildren
            inboundRelations = @()
        }
        attachment = [pscustomobject][ordered]@{
            key = $attachmentKey
            version = Get-RequiredPropertyValue -Object $Attachment -Name "version"
            relations = Get-OptionalPropertyValue -Object $attachmentData -Name "relations"
            tags = @(Get-OptionalPropertyValue -Object $attachmentData -Name "tags")
            hasAnnotations = $annotations.Count -gt 0
            isFinal = Test-LiveFormalFinalAttachment -AttachmentData $attachmentData
        }
        storage = [pscustomobject][ordered]@{
            path = [IO.Path]::GetFullPath($storageDirectory)
            pdfPath = [IO.Path]::GetFullPath($storagePdfs[0].FullName)
            sha256 = $storageHash
        }
        cache = $cache
        local = $local
        userStateEmpty = Test-LiveCleanupUserStateEmpty `
            -Parent $Parent `
            -Attachment $Attachment `
            -Items $Items
    }
}

function Find-LiveMinimalDuplicateCandidate {
    param(
        [Parameter(Mandatory = $true)][object]$Scope,
        [Parameter(Mandatory = $true)][object[]]$Targets,
        [Parameter(Mandatory = $true)][scriptblock]$ReadAllItems
    )

    $items = @(& $ReadAllItems $Scope)
    $itemsByKey = @{}
    foreach ($item in $items) {
        $itemsByKey[[string](Get-RequiredPropertyValue -Object $item -Name "key")] = $item
    }
    $sides = @(
        foreach ($target in $Targets) {
            $parentKey = [string](Get-RequiredPropertyValue -Object $target -Name "parentItemKey")
            $attachmentKey = [string](Get-RequiredPropertyValue -Object $target -Name "attachmentKey")
            if (-not $itemsByKey.ContainsKey($parentKey) -or
                -not $itemsByKey.ContainsKey($attachmentKey)) {
                continue
            }
            ConvertTo-LiveCleanupSide `
                -Scope $Scope `
                -Parent $itemsByKey[$parentKey] `
                -Attachment $itemsByKey[$attachmentKey] `
                -Items $items
        }
    )
    $groups = @(
        $sides |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace(
                    (ConvertTo-DuplicateDoi -Doi ([string]$_.parent.doi)
                ))
            } |
            Group-Object { ConvertTo-DuplicateDoi -Doi ([string]$_.parent.doi) }
    )
    @(
        foreach ($group in $groups) {
            $members = @($group.Group)
            if ($members.Count -ne 2 -or
                [string]$members[0].cache.fullMdSha256 -cne
                    [string]$members[1].cache.fullMdSha256) {
                continue
            }
            $emptyMembers = @($members | Where-Object { $_.userStateEmpty })
            if ($emptyMembers.Count -eq 0) { continue }
            if ($emptyMembers.Count -eq 1) {
                $remove = $emptyMembers[0]
                $retain = @($members | Where-Object { $_.parent.key -cne $remove.parent.key })[0]
            }
            else {
                $ordered = @(
                    $members |
                        Sort-Object `
                            @{ Expression = { [string]$_.parent.dateAdded } }, `
                            @{ Expression = { [string]$_.parent.key } }
                )
                $retain = $ordered[0]
                $remove = $ordered[1]
            }
            [pscustomobject][ordered]@{ retain = $retain; remove = $remove }
        }
    )
}

function Get-LiveDuplicateConsolidationGroupSnapshot {
    param(
        [Parameter(Mandatory = $true)][object]$Scope,
        [Parameter(Mandatory = $true)][object[]]$Targets,
        [Parameter(Mandatory = $true)][scriptblock]$ReadAllItems
    )

    $items = @(& $ReadAllItems $Scope)
    $itemsByKey = @{}
    foreach ($item in $items) {
        $itemsByKey[[string](Get-RequiredPropertyValue -Object $item -Name "key")] = $item
    }
    $sides = @(
        foreach ($target in $Targets) {
            $parentKey = [string](Get-RequiredPropertyValue -Object $target -Name "parentItemKey")
            $attachmentKey = [string](Get-RequiredPropertyValue -Object $target -Name "attachmentKey")
            if (-not $itemsByKey.ContainsKey($parentKey) -or
                -not $itemsByKey.ContainsKey($attachmentKey)) {
                continue
            }
            ConvertTo-LiveCleanupSide `
                -Scope $Scope `
                -Parent $itemsByKey[$parentKey] `
                -Attachment $itemsByKey[$attachmentKey] `
                -Items $items
        }
    )
    foreach ($side in $sides) {
        $parentKey = [string]$side.parent.key
        $inbound = @(
            foreach ($item in $items) {
                $data = Get-LiveCleanupItemData -Item $item
                $relations = Get-OptionalPropertyValue -Object $data -Name "relations"
                if ($null -eq $relations) { continue }
                foreach ($property in $relations.PSObject.Properties) {
                    foreach ($value in @($property.Value)) {
                        if ([string]$value -match "/items/$([regex]::Escape($parentKey))$") {
                            [pscustomobject][ordered]@{
                                sourceKey = [string]$item.key
                                sourceVersion = Get-RequiredPropertyValue -Object $item -Name "version"
                                predicate = [string]$property.Name
                                oldTargetValue = [string]$value
                            }
                        }
                    }
                }
            }
        )
        $side.parent.inboundRelations = $inbound
    }
    $groups = @(
        $sides | Group-Object { Get-DuplicateDiscoveryKey -Member $_ }
    )
    @(
        foreach ($group in $groups) {
            if (@($group.Group).Count -ge 2) {
                [pscustomobject][ordered]@{ members = @($group.Group) }
            }
        }
    )
}

function ConvertTo-LiveCleanupMcpResponse {
    param([Parameter(Mandatory = $true)][object]$Response)

    $rpcError = Get-OptionalPropertyValue -Object $Response -Name "error"
    if ($null -ne $rpcError) {
        throw "llm-for-zotero MCP returned an error: $($rpcError | ConvertTo-Json -Depth 10 -Compress)"
    }
    $result = Get-RequiredPropertyValue -Object $Response -Name "result"
    if ([bool](Get-OptionalPropertyValue -Object $result -Name "isError")) {
        throw "llm-for-zotero MCP tool call failed."
    }
}

function Invoke-LiveCleanupScript {
    param(
        [Parameter(Mandatory = $true)][string]$Script,
        [Parameter(Mandatory = $true)][scriptblock]$McpAdapter
    )

    $response = & $McpAdapter ([pscustomobject]@{ script = $Script })
    ConvertTo-LiveCleanupMcpResponse -Response $response
}

function ConvertTo-LiveCleanupBase64 {
    param([Parameter(Mandatory = $true)][object]$Value)

    [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 20 -Compress))
    )
}

function Assert-LiveCleanupClosure {
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][object]$Scope,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory = $true)][string]$CacheRoot
    )

    $retainParentKey = [string]$Plan.retain.parent.key
    $retainAttachmentKey = [string]$Plan.retain.attachment.key
    $retainParent = @($Items | Where-Object { [string]$_.key -ceq $retainParentKey })
    $retainAttachment = @($Items | Where-Object { [string]$_.key -ceq $retainAttachmentKey })
    if ($retainParent.Count -ne 1 -or $retainAttachment.Count -ne 1) {
        throw "retained Zotero parent or attachment is missing or ambiguous"
    }
    $attachmentData = Get-LiveCleanupItemData -Item $retainAttachment[0]
    if ([string](Get-OptionalPropertyValue -Object $attachmentData -Name "parentItem") -cne
        $retainParentKey) {
        throw "retained attachment is no longer attached to the retained parent"
    }
    $retainSide = ConvertTo-LiveCleanupSide `
        -Scope $Scope `
        -Parent $retainParent[0] `
        -Attachment $retainAttachment[0] `
        -Items $Items
    if ($null -eq $retainSide -or -not [bool]$retainSide.cache.healthy) {
        throw "retained storage, local PDF, or healthy MinerU cache is missing"
    }
    if ([string]$retainSide.storage.sha256 -cne [string]$Plan.retain.storage.sha256 -or
        [string]$retainSide.local.sha256 -cne [string]$Plan.retain.local.sha256 -or
        [string]$retainSide.cache.fullMdSha256 -cne
            [string]$Plan.retain.cache.fullMdSha256) {
        throw "retained storage, local PDF, or MinerU Markdown hash drifted"
    }
    $localName = [IO.Path]::GetFileName([string]$retainSide.local.path)
    if ([string]::IsNullOrWhiteSpace($localName) -or
        [IO.Path]::GetExtension($localName) -ine ".pdf") {
        throw "retained local PDF no longer has a valid current basename"
    }

    $losingKeys = @(
        @($Plan.deleteKeys) +
        @(
            $removals = if ($null -ne (
                Get-OptionalPropertyValue -Object $Plan -Name "removals"
            )) {
                @($Plan.removals)
            }
            else {
                @($Plan.remove)
            }
            foreach ($member in $removals) {
                @($member.parent.childKeys)
                @($member.parent.notes)
                @($member.parent.unknownChildren)
            }
        ) |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
    foreach ($item in $Items) {
        if ([string]$item.key -cin $losingKeys) {
            throw "losing Zotero key '$($item.key)' still exists"
        }
        $data = Get-LiveCleanupItemData -Item $item
        $relations = Get-OptionalPropertyValue -Object $data -Name "relations"
        if ($null -eq $relations) { continue }
        foreach ($property in $relations.PSObject.Properties) {
            foreach ($value in @($property.Value)) {
                foreach ($key in $losingKeys) {
                    if ([string]$value -match "/items/$([regex]::Escape($key))$") {
                        throw "relation on '$($item.key)' still points to losing key '$key'"
                    }
                }
            }
        }
    }
    if (Test-Path -LiteralPath $CacheRoot -PathType Container) {
        foreach ($sourceFile in Get-ChildItem `
            -LiteralPath $CacheRoot `
            -Filter "_llm_source.json" `
            -File `
            -Recurse) {
            $source = Get-Content -LiteralPath $sourceFile.FullName -Raw |
                ConvertFrom-Json -Depth 20
            if ([string]$source.attachmentKey -cin $losingKeys -or
                [string]$source.parentItemKey -cin $losingKeys) {
                throw "MinerU provenance '$($sourceFile.FullName)' still points to a losing key"
            }
        }
    }
}

function Assert-LiveTrashedCleanupEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][object]$Scope,
        [Parameter(Mandatory = $true)][object[]]$Items
    )

    $byKey = @{}
    foreach ($item in $Items) { $byKey[[string]$item.key] = $item }
    $removals = if ($null -ne (Get-OptionalPropertyValue -Object $Plan -Name "removals")) {
        @($Plan.removals)
    }
    else {
        @($Plan.remove)
    }
    foreach ($expected in $removals) {
        $parentKey = [string]$expected.parent.key
        $attachmentKey = [string]$expected.attachment.key
        if (-not $byKey.ContainsKey($parentKey) -or
            -not $byKey.ContainsKey($attachmentKey)) {
            throw (New-ZpuTypedException `
                -Code "cleanup_drift_trash" `
                -Message "Expected trashed parent or attachment disappeared before purge.")
        }
        $actual = ConvertTo-LiveCleanupSide `
            -Scope $Scope `
            -Parent $byKey[$parentKey] `
            -Attachment $byKey[$attachmentKey] `
            -Items $Items
        if ($null -eq $actual) {
            throw (New-ZpuTypedException `
                -Code "cleanup_drift_zotero_state" `
                -Message "Trashed Zotero object assets or child evidence no longer resolves.")
        }
        $expectedParent = [Management.Automation.PSSerializer]::Deserialize(
            [Management.Automation.PSSerializer]::Serialize($expected.parent, 20)
        )
        $expectedAttachment = [Management.Automation.PSSerializer]::Deserialize(
            [Management.Automation.PSSerializer]::Serialize($expected.attachment, 20)
        )
        $actualParentVersion = [int]$actual.parent.version
        $expectedParentVersion = [int]$expectedParent.version
        $parentVersionMatches = $actualParentVersion -eq $expectedParentVersion -or
            $actualParentVersion -eq ($expectedParentVersion + 1)
        $actualAttachmentVersion = [int]$actual.attachment.version
        $expectedAttachmentVersion = [int]$expectedAttachment.version
        $attachmentVersionMatches = $actualAttachmentVersion -eq $expectedAttachmentVersion -or
            $actualAttachmentVersion -eq ($expectedAttachmentVersion + 1)
        $actual.parent.version = $null
        $actual.attachment.version = $null
        $expectedParent.version = $null
        $expectedAttachment.version = $null
        if (-not $parentVersionMatches -or -not $attachmentVersionMatches -or
            -not (Test-DeepValueEqual -Left $actual.parent -Right $expectedParent) -or
            -not (Test-DeepValueEqual -Left $actual.attachment -Right $expectedAttachment)) {
            throw (New-ZpuTypedException `
                -Code "cleanup_drift_zotero_state" `
                -Message "Trashed Zotero identity, version, relation, note, or annotation evidence drifted.")
        }
    }
}

function Get-LiveDuplicateCleanupOperationTable {
    param(
        [Parameter(Mandatory = $true)][object]$Scope,
        [Parameter(Mandatory = $true)][scriptblock]$ReadAllItems,
        [Parameter(Mandatory = $true)][scriptblock]$ReadTrashItems,
        [Parameter(Mandatory = $true)][scriptblock]$McpAdapter
    )

    $null = @($Scope, $ReadAllItems, $ReadTrashItems, $McpAdapter)
    $findCandidates = {
        param($Scope, $Targets)
        ZoteroPaperUpdater.DuplicateCleanupLive\Find-LiveMinimalDuplicateCandidate `
            -Scope $Scope `
            -Targets $Targets `
            -ReadAllItems $ReadAllItems
    }.GetNewClosure()
    $readLiveState = {
        param($Plan)
        $candidates = @(
            ZoteroPaperUpdater.DuplicateCleanupLive\Find-LiveMinimalDuplicateCandidate `
                -Scope $Plan.scope `
                -Targets @(
                    [pscustomobject]@{
                        parentItemKey = $Plan.retain.parent.key
                        attachmentKey = $Plan.retain.attachment.key
                    },
                    [pscustomobject]@{
                        parentItemKey = $Plan.remove.parent.key
                        attachmentKey = $Plan.remove.attachment.key
                    }
                ) `
                -ReadAllItems $ReadAllItems
        )
        if ($candidates.Count -ne 1) { return $null }
        [pscustomobject][ordered]@{
            retain = $candidates[0].retain
            remove = $candidates[0].remove
        }
    }.GetNewClosure()
    $readConsolidationMembers = {
        param($Decision)
        $items = @(& $ReadAllItems $Scope)
        $byKey = @{}
        foreach ($item in $items) { $byKey[[string]$item.key] = $item }
        @(
            foreach ($member in @($Decision.members)) {
                $parentKey = [string]$member.parent.key
                $attachmentKey = [string]$member.attachment.key
                if (-not $byKey.ContainsKey($parentKey) -or
                    -not $byKey.ContainsKey($attachmentKey)) {
                    throw "A consolidation source item disappeared before the atomic write."
                }
                ZoteroPaperUpdater.DuplicateCleanupLive\ConvertTo-LiveCleanupSide `
                    -Scope $Scope `
                    -Parent $byKey[$parentKey] `
                    -Attachment $byKey[$attachmentKey] `
                    -Items $items
            }
        )
    }.GetNewClosure()
    $applyConsolidation = {
        param($Decision)
        if (-not [bool]$Decision.requiresWrite) {
            return [pscustomobject]@{ status = "already_applied" }
        }
        $readItem = {
            param($Key)
            @(& $ReadAllItems $Scope | Where-Object { [string]$_.key -ceq [string]$Key })[0]
        }.GetNewClosure()
        $result = ZoteroPaperUpdater.ZoteroWriter\Invoke-ZoteroConsolidationWrite `
            -Decision $Decision `
            -ReadAdapter $readItem `
            -McpAdapter $McpAdapter
        if ([string]$result.status -in @("written", "already_applied") -and
            $null -ne $Decision.attachmentWriteRequest) {
            $selected = @(
                $Decision.members | Where-Object {
                    [string]$_.attachment.key -ceq [string]$Decision.retainedAttachment.key
                }
            )[0]
            $sourcePath = Join-Path $selected.cache.path "_llm_source.json"
            $source = Get-Content -LiteralPath $sourcePath -Raw | ConvertFrom-Json -Depth 20
            $source.parentItemKey = [string]$Decision.retainedParent.key
            [IO.File]::WriteAllText(
                $sourcePath,
                ($source | ConvertTo-Json -Depth 20),
                [Text.UTF8Encoding]::new($false)
            )
        }
        $result
    }.GetNewClosure()
    $getTrashKeys = {
        @(
            & $ReadTrashItems |
                ForEach-Object { [string]$_.key }
        )
    }.GetNewClosure()
    $trashZotero = {
        param($Keys)
        $payload = ZoteroPaperUpdater.DuplicateCleanupLive\ConvertTo-LiveCleanupBase64 -Value @($Keys)
        $scriptText = @"
const keys = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob("$payload"), c => c.charCodeAt(0))));
for (const key of keys) {
  const item = await Zotero.Items.getByLibraryAndKeyAsync(env.libraryID, key);
  if (!item) throw new Error("Cleanup item missing: " + key);
  env.snapshot(item);
  item.deleted = true;
  await item.saveTx();
}
env.log(JSON.stringify({status:"trashed", keys}));
"@
        ZoteroPaperUpdater.DuplicateCleanupLive\Invoke-LiveCleanupScript `
            -Script $scriptText `
            -McpAdapter $McpAdapter
    }.GetNewClosure()
    $getExistingZoteroKeys = {
        param($Keys)
        $all = @(& $ReadAllItems $Scope) + @(& $ReadTrashItems)
        @(
            $all |
                ForEach-Object { [string]$_.key } |
                Where-Object { $_ -cin @($Keys) }
        )
    }.GetNewClosure()
    $getLiveZoteroKeys = {
        param($Keys)
        @(
            & $ReadAllItems $Scope |
                ForEach-Object { [string]$_.key } |
                Where-Object { $_ -cin @($Keys) }
        )
    }.GetNewClosure()
    $readAssetEvidence = {
        param($Plan, $ExpectedEvidence)
        ZoteroPaperUpdater.DuplicateCleanupLive\Get-LiveCleanupAssetEvidence `
            -Plan $Plan `
            -ExpectedEvidence $ExpectedEvidence
    }.GetNewClosure()
    $purgeZotero = {
        param($Keys)
        $payload = ZoteroPaperUpdater.DuplicateCleanupLive\ConvertTo-LiveCleanupBase64 -Value @($Keys)
        $scriptText = @"
const expected = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob("$payload"), c => c.charCodeAt(0)))).sort();
const trashed = (await Zotero.Items.getDeleted(env.libraryID))
  .map(id => Zotero.Items.get(id)?.key)
  .filter(Boolean)
  .sort();
if (JSON.stringify(trashed) !== JSON.stringify(expected)) {
  throw new Error("Trash changed before permanent purge");
}
await Zotero.Items.emptyTrash(env.libraryID);
env.log(JSON.stringify({status:"purged", keys:expected}));
"@
        ZoteroPaperUpdater.DuplicateCleanupLive\Invoke-LiveCleanupScript `
            -Script $scriptText `
            -McpAdapter $McpAdapter
    }.GetNewClosure()
    $getExistingPaths = {
        param($Kind, $Paths)
        $null = $Kind
        @($Paths | Where-Object { Test-Path -LiteralPath $_ })
    }.GetNewClosure()
    $removePaths = {
        param($Paths)
        foreach ($path in @($Paths)) {
            if (Test-Path -LiteralPath $path -PathType Container) {
                Remove-Item -LiteralPath $path -Recurse -Force
            }
            elseif (Test-Path -LiteralPath $path -PathType Leaf) {
                Remove-Item -LiteralPath $path -Force
            }
        }
    }.GetNewClosure()
    $assertNoOrphans = {
        param($Plan)
        $allItems = @(& $ReadAllItems $Scope) + @(& $ReadTrashItems)
        $cacheRoot = Join-Path $Scope.zoteroDataDir "llm-for-zotero-mineru"
        ZoteroPaperUpdater.DuplicateCleanupLive\Assert-LiveCleanupClosure `
            -Plan $Plan `
            -Scope $Scope `
            -Items $allItems `
            -CacheRoot $cacheRoot
    }.GetNewClosure()
    $assertTrashedEvidence = {
        param($Plan)
        $items = @(& $ReadAllItems $Scope) + @(& $ReadTrashItems)
        ZoteroPaperUpdater.DuplicateCleanupLive\Assert-LiveTrashedCleanupEvidence `
            -Plan $Plan `
            -Scope $Scope `
            -Items $items
    }.GetNewClosure()
    [pscustomobject]@{
        FindCandidates = $findCandidates
        ReadLiveState = $readLiveState
        ReadConsolidationMembers = $readConsolidationMembers
        ApplyConsolidation = $applyConsolidation
        GetTrashKeys = $getTrashKeys
        TrashZotero = $trashZotero
        GetExistingZoteroKeys = $getExistingZoteroKeys
        GetLiveZoteroKeys = $getLiveZoteroKeys
        PurgeZotero = $purgeZotero
        ReadAssetEvidence = $readAssetEvidence
        GetExistingPaths = $getExistingPaths
        RemoveStorage = $removePaths
        RemoveCache = $removePaths
        RemoveLocal = $removePaths
        AssertNoOrphans = $assertNoOrphans
        AssertTrashedZoteroEvidence = $assertTrashedEvidence
    }
}

Export-ModuleMember -Function `
    Get-LiveDuplicateCleanupOperationTable, `
    Get-LiveDuplicateConsolidationGroupSnapshot, `
    Find-LiveMinimalDuplicateCandidate, `
    ConvertTo-LiveCleanupSide, `
    Test-LiveFormalFinalAttachment, `
    Get-LiveCleanupAssetEvidence, `
    ConvertTo-LiveCleanupBase64, `
    Invoke-LiveCleanupScript, `
    Assert-LiveCleanupClosure, `
    Assert-LiveTrashedCleanupEvidence
