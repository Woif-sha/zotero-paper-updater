Set-StrictMode -Version Latest

$commonModulePath = Join-Path $PSScriptRoot "ZoteroPaperUpdater.Common.psm1"
Import-Module -Name $commonModulePath -DisableNameChecking

$script:UserStateProperties = @(
    "tags",
    "collections",
    "notes",
    "attachments",
    "annotations",
    "relations",
    "extra"
)

function Get-FirstAuthorName {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Creators
    )

    $author = @(
        $Creators |
            Where-Object {
                (Get-OptionalPropertyValue -Object $_ -Name "creatorType") -eq "author"
            } |
            Select-Object -First 1
    )
    if ($author.Count -eq 0) {
        throw "Title metadata lookup requires at least one author."
    }

    $firstName = [string](Get-OptionalPropertyValue -Object $author[0] -Name "firstName")
    $lastName = [string](Get-OptionalPropertyValue -Object $author[0] -Name "lastName")
    $name = "$firstName $lastName".Trim()
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = [string](Get-OptionalPropertyValue -Object $author[0] -Name "name")
    }
    if ([string]::IsNullOrWhiteSpace($name)) {
        throw "Title metadata lookup requires a complete first-author name."
    }
    $name
}

function New-MetadataQuery {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Constructs an in-memory query and does not change external state."
    )]
    param(
        [Parameter(Mandatory = $true)]
        [object]$ParentItem
    )

    $fields = Get-RequiredPropertyValue -Object $ParentItem -Name "fields"
    $doi = [string](Get-OptionalPropertyValue -Object $fields -Name "DOI")
    if (-not [string]::IsNullOrWhiteSpace($doi)) {
        return [pscustomobject][ordered]@{
            kind = "doi"
            value = $doi.Trim()
        }
    }

    $title = [string](Get-OptionalPropertyValue -Object $fields -Name "title")
    if ([string]::IsNullOrWhiteSpace($title)) {
        throw "Metadata lookup requires either a DOI or a complete title."
    }
    $creators = @(Get-OptionalPropertyValue -Object $fields -Name "creators")
    [pscustomobject][ordered]@{
        kind = "title_first_author"
        title = $title
        firstAuthor = Get-FirstAuthorName -Creators $creators
    }
}

function Select-SourceBibliographicFieldSet {
    param(
        [Parameter(Mandatory = $true)]
        [object]$SourceFields
    )

    $selected = [ordered]@{}
    foreach ($property in $SourceFields.PSObject.Properties) {
        if ($property.Name -in $script:UserStateProperties -or $null -eq $property.Value) {
            continue
        }
        if ($property.Value -is [string] -and [string]::IsNullOrWhiteSpace($property.Value)) {
            continue
        }
        $selected[$property.Name] = $property.Value
    }
    [pscustomobject]$selected
}

function ConvertTo-MetadataSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Fields,

        [Parameter(Mandatory = $true)]
        [string[]]$Names,

        [AllowNull()]
        [string]$ItemType,

        [Parameter(Mandatory = $true)]
        [bool]$IncludeItemType
    )

    $snapshot = [ordered]@{}
    foreach ($name in $Names) {
        $snapshot[$name] = Get-OptionalPropertyValue -Object $Fields -Name $name
    }
    if ($IncludeItemType) {
        $snapshot["itemType"] = $ItemType
    }
    [pscustomobject]$snapshot
}

function Test-MetadataChanged {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Before,

        [Parameter(Mandatory = $true)]
        [object]$After
    )

    -not (Test-DeepValueEqual -Left $Before -Right $After)
}

function New-MetadataNoOpResult {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Constructs an in-memory result and does not change external state."
    )]
    param()

    [pscustomobject][ordered]@{
        status = "succeeded"
        actions = @()
        issues = @()
    }
}

function Test-MetadataMatchAccepted {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Match
    )

    if (-not [bool](Get-RequiredPropertyValue -Object $Match -Name "matched")) {
        return $false
    }

    [bool](Get-RequiredPropertyValue -Object $Match -Name "exact") -and
        [bool](Get-RequiredPropertyValue -Object $Match -Name "reliable") -and
        [bool](Get-RequiredPropertyValue -Object $Match -Name "formal")
}

function New-MetadataWritePlan {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Constructs an in-memory write plan and does not change external state."
    )]
    param(
        [Parameter(Mandatory = $true)]
        [object]$ParentItem,

        [Parameter(Mandatory = $true)]
        [object]$Match
    )

    $record = Get-RequiredPropertyValue -Object $Match -Name "record"
    $sourceFields = Get-RequiredPropertyValue -Object $record -Name "fields"
    $writeFields = Select-SourceBibliographicFieldSet -SourceFields $sourceFields
    $fieldNames = @($writeFields.PSObject.Properties.Name)
    $sourceItemType = [string](Get-OptionalPropertyValue -Object $record -Name "itemType")
    $hasExplicitItemType = -not [string]::IsNullOrWhiteSpace($sourceItemType)
    $currentItemType = [string](Get-RequiredPropertyValue -Object $ParentItem -Name "itemType")
    $currentFields = Get-RequiredPropertyValue -Object $ParentItem -Name "fields"
    $before = ConvertTo-MetadataSnapshot `
        -Fields $currentFields `
        -Names $fieldNames `
        -ItemType $currentItemType `
        -IncludeItemType $hasExplicitItemType
    $after = ConvertTo-MetadataSnapshot `
        -Fields $writeFields `
        -Names $fieldNames `
        -ItemType $sourceItemType `
        -IncludeItemType $hasExplicitItemType
    $expectedVersion = Get-RequiredPropertyValue -Object $ParentItem -Name "version"
    $writeRequestValues = [ordered]@{
        parentItemKey = Get-RequiredPropertyValue -Object $ParentItem -Name "key"
        expectedVersion = $expectedVersion
        fields = $writeFields
    }
    if ($hasExplicitItemType) {
        $writeRequestValues["itemType"] = $sourceItemType
    }

    [pscustomobject][ordered]@{
        shouldWrite = Test-MetadataChanged -Before $before -After $after
        request = [pscustomobject]$writeRequestValues
        expectedVersion = $expectedVersion
        before = $before
        fieldNames = @($fieldNames)
        includeItemType = $hasExplicitItemType
    }
}

function ConvertTo-MetadataWriteOutcome {
    param(
        [Parameter(Mandatory = $true)]
        [object]$WriteResult,

        [Parameter(Mandatory = $true)]
        [object]$Plan,

        [Parameter(Mandatory = $true)]
        [object]$Match,

        [Parameter(Mandatory = $true)]
        [object]$Target
    )

    $writeStatus = [string](Get-RequiredPropertyValue -Object $WriteResult -Name "status")
    if ($writeStatus -eq "version_conflict") {
        $actualVersion = Get-OptionalPropertyValue -Object $WriteResult -Name "actualVersion"
        return [pscustomobject][ordered]@{
            status = "failed"
            actions = @()
            issues = @(
                [pscustomobject][ordered]@{
                    severity = "error"
                    code = "metadata_version_conflict"
                    target = $Target
                    message = "Metadata write rejected because the Zotero item version changed."
                    evidence = @(
                        "expectedVersion=$($Plan.expectedVersion)",
                        "actualVersion=$actualVersion"
                    )
                }
            )
        }
    }
    if ($writeStatus -ne "written") {
        throw "Metadata write adapter returned unsupported status '$writeStatus'."
    }

    $writtenFields = Get-RequiredPropertyValue -Object $WriteResult -Name "fields"
    $writtenItemType = [string](Get-OptionalPropertyValue -Object $WriteResult -Name "itemType")
    $actualAfter = ConvertTo-MetadataSnapshot `
        -Fields $writtenFields `
        -Names @($Plan.fieldNames) `
        -ItemType $writtenItemType `
        -IncludeItemType $Plan.includeItemType
    [pscustomobject][ordered]@{
        status = "succeeded"
        actions = @(
            [pscustomobject][ordered]@{
                category = "modified"
                kind = "metadata_completed"
                target = $Target
                before = $Plan.before
                after = $actualAfter
                evidence = @(Get-RequiredPropertyValue -Object $Match -Name "evidence")
            }
        )
        issues = @()
    }
}

function Invoke-MetadataEnrichment {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ParentItem,

        [Parameter(Mandatory = $true)]
        [object]$Target,

        [Parameter(Mandatory = $true)]
        [scriptblock]$QueryAdapter,

        [Parameter(Mandatory = $true)]
        [scriptblock]$WriteAdapter
    )

    $match = & $QueryAdapter (New-MetadataQuery -ParentItem $ParentItem)
    if (-not (Test-MetadataMatchAccepted -Match $match)) {
        return New-MetadataNoOpResult
    }

    $plan = New-MetadataWritePlan -ParentItem $ParentItem -Match $match
    if (-not $plan.shouldWrite) {
        return New-MetadataNoOpResult
    }

    $writeResult = & $WriteAdapter $plan.request
    ConvertTo-MetadataWriteOutcome -WriteResult $writeResult -Plan $plan -Match $match -Target $Target
}

Export-ModuleMember -Function Invoke-MetadataEnrichment
