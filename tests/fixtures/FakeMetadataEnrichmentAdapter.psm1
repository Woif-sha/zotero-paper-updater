Set-StrictMode -Version Latest

$metadataModulePath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) `
    "scripts\ZoteroPaperUpdater.MetadataEnrichment.psm1"
Import-Module -Name $metadataModulePath -Force -DisableNameChecking

function Add-FakeCall {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Operation,

        [Parameter(Mandatory = $true)]
        [object]$Payload
    )

    $record = [pscustomobject][ordered]@{
        operation = $Operation
        payload = $Payload
    }
    [System.IO.File]::AppendAllText(
        $env:ZPU_METADATA_CALL_LOG,
        (($record | ConvertTo-Json -Depth 20 -Compress) + [Environment]::NewLine),
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Get-MaintenanceZoteroItem {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Scope
    )

    $null = $Scope
    @(
        [pscustomobject][ordered]@{
            key = "PARN2222"
            version = 7
            data = [pscustomobject][ordered]@{
                key = "PARN2222"
                version = 7
                itemType = "journalArticle"
                title = "Exact Paper Title"
            }
        },
        [pscustomobject][ordered]@{
            key = "ATTCH222"
            version = 2
            data = [pscustomobject][ordered]@{
                key = "ATTCH222"
                version = 2
                itemType = "attachment"
                parentItem = "PARN2222"
                contentType = "application/pdf"
                filename = "metadata.pdf"
            }
        }
    )
}

function Invoke-MaintenanceTarget {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Target,

        [Parameter(Mandatory = $true)]
        [object]$Scope
    )

    $null = $Scope
    $scenario = $env:ZPU_METADATA_SCENARIO
    $parent = [pscustomobject][ordered]@{
        key = $Target.parentItemKey
        version = 7
        itemType = "journalArticle"
        fields = [pscustomobject][ordered]@{
            title = "Exact Paper Title"
            creators = @(
                [pscustomobject][ordered]@{
                    creatorType = "author"
                    firstName = "Ada"
                    lastName = "Lovelace"
                }
            )
            DOI = if ($scenario -eq "title-match") { $null } else { "10.1000/exact" }
            date = "2024"
            publicationTitle = "Old Journal"
            volume = "3"
            issue = "2"
            pages = "10-20"
            url = "https://old.example/paper"
            abstractNote = "User-curated abstract"
        }
        userState = [pscustomobject][ordered]@{
            tags = @("keep-tag")
            collections = @("COLLECTION1")
            notes = @("NOTE1")
            attachments = @("ATTACH-METADATA")
            annotations = @("ANNOTATION1")
            relations = [pscustomobject]@{ "dc:relation" = "keep-relation" }
        }
    }

    $queryAdapter = {
        param($Query)

        Add-FakeCall -Operation "query" -Payload $Query
        if ($env:ZPU_METADATA_SCENARIO -eq "no-match") {
            return [pscustomobject][ordered]@{ matched = $false }
        }

        $exact = $env:ZPU_METADATA_SCENARIO -ne "inexact-match"
        $reliable = $env:ZPU_METADATA_SCENARIO -ne "unreliable-match"
        $formal = $env:ZPU_METADATA_SCENARIO -ne "informal-match"
        $recordFields = [ordered]@{
            title = "Exact Paper Title"
            creators = @(
                [pscustomobject][ordered]@{
                    creatorType = "author"
                    firstName = "Ada"
                    lastName = "Lovelace"
                }
            )
            DOI = "10.1000/exact"
            date = "2025"
            publicationTitle = "Formal Journal"
            volume = "4"
            pages = "101-119"
            reportNumber = "R-42"
            url = "https://publisher.example/paper"
            extra = "Source-owned note must not overwrite user Extra"
            tags = @("source-tag")
        }
        if ($env:ZPU_METADATA_SCENARIO -eq "sparse-record") {
            $recordFields = [ordered]@{
                date = "2025"
                publicationTitle = "Formal Journal"
                volume = $null
                issue = ""
                pages = "   "
            }
        }
        elseif ($env:ZPU_METADATA_SCENARIO -eq "exact-unchanged") {
            $recordFields = [ordered]@{
                title = $parent.fields.title
                creators = $parent.fields.creators
                DOI = $parent.fields.DOI
                date = $parent.fields.date
                publicationTitle = $parent.fields.publicationTitle
                volume = $parent.fields.volume
                issue = $parent.fields.issue
                pages = $parent.fields.pages
                url = $parent.fields.url
                abstractNote = $parent.fields.abstractNote
            }
        }
        elseif ($env:ZPU_METADATA_SCENARIO -eq "property-order-unchanged") {
            $recordFields = [ordered]@{
                title = $parent.fields.title
                creators = @(
                    [pscustomobject][ordered]@{
                        lastName = "Lovelace"
                        firstName = "Ada"
                        creatorType = "author"
                    }
                )
                DOI = $parent.fields.DOI
                date = $parent.fields.date
                publicationTitle = $parent.fields.publicationTitle
                volume = $parent.fields.volume
                issue = $parent.fields.issue
                pages = $parent.fields.pages
                url = $parent.fields.url
                abstractNote = $parent.fields.abstractNote
            }
        }

        [pscustomobject][ordered]@{
            matched = $true
            exact = $exact
            reliable = $reliable
            formal = $formal
            evidence = @(
                "https://doi.org/10.1000/exact",
                "registry:formal-record"
            )
            record = [pscustomobject][ordered]@{
                fields = [pscustomobject]$recordFields
                itemType = if ($env:ZPU_METADATA_SCENARIO -eq "explicit-item-type") {
                    "conferencePaper"
                }
                else {
                    $null
                }
            }
        }
    }

    $writeAdapter = {
        param($WriteRequest)

        Add-FakeCall -Operation "write" -Payload $WriteRequest
        if ($env:ZPU_METADATA_SCENARIO -eq "version-conflict") {
            return [pscustomobject][ordered]@{
                status = "version_conflict"
                actualVersion = 8
            }
        }

        [pscustomobject][ordered]@{
            status = "written"
            version = 8
            fields = $WriteRequest.fields
            itemType = if ($WriteRequest.PSObject.Properties.Name -contains "itemType") {
                $WriteRequest.itemType
            }
            else {
                $parent.itemType
            }
        }
    }

    Invoke-MetadataEnrichment `
        -ParentItem $parent `
        -Target $Target `
        -QueryAdapter $queryAdapter `
        -WriteAdapter $writeAdapter
}

Export-ModuleMember -Function Get-MaintenanceZoteroItem, Invoke-MaintenanceTarget
