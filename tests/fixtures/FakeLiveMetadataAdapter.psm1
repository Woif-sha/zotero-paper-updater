Set-StrictMode -Version Latest

$productionPath = Join-Path $PSScriptRoot `
    "ZoteroPaperUpdater.ProductionMaintenanceAdapters.psm1"
$script:ProductionModule = Import-Module `
    -Name $productionPath `
    -Force `
    -PassThru `
    -DisableNameChecking `
    -WarningAction SilentlyContinue
$script:ReadCount = 0

function Add-LiveAdapterCall {
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
        $env:ZPU_LIVE_ADAPTER_CALL_LOG,
        (($record | ConvertTo-Json -Depth 20 -Compress) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
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
            key = "PARENT22"
            version = 7
            data = [pscustomobject][ordered]@{
                key = "PARENT22"
                version = 7
                itemType = "journalArticle"
                title = "Production Wiring Paper"
                creators = @(
                    [pscustomobject][ordered]@{
                        creatorType = "author"
                        firstName = "Ada"
                        lastName = "Lovelace"
                    }
                )
                DOI = "10.1000/production"
                date = "2024"
                publicationTitle = "Old Journal"
                tags = @([pscustomobject]@{ tag = "keep" })
                collections = @("COLL0001")
                relations = [pscustomobject]@{ "dc:relation" = "keep-relation" }
            }
        },
        [pscustomobject][ordered]@{
            key = "ATTACH22"
            version = 3
            data = [pscustomobject][ordered]@{
                key = "ATTACH22"
                version = 3
                itemType = "attachment"
                parentItem = "PARENT22"
                contentType = "application/pdf"
                filename = "Canonical Paper.pdf"
            }
        }
    )
}

function New-FakeLiveParent {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Constructs an in-memory live-item fixture."
    )]
    param(
        [Parameter(Mandatory = $true)]
        [bool]$AfterWrite
    )

    [pscustomobject][ordered]@{
        key = "PARENT22"
        version = if ($AfterWrite) { 8 } else { 7 }
        data = [pscustomobject][ordered]@{
            key = "PARENT22"
            version = if ($AfterWrite) { 8 } else { 7 }
            itemType = "journalArticle"
            title = "Production Wiring Paper"
            creators = @(
                [pscustomobject][ordered]@{
                    creatorType = "author"
                    firstName = "Ada"
                    lastName = "Lovelace"
                }
            )
            DOI = "10.1000/production"
            date = if ($AfterWrite) { "2025" } else { "2024" }
            publicationTitle = if ($AfterWrite) { "Formal Journal" } else { "Old Journal" }
            url = if ($AfterWrite) { "https://doi.org/10.1000/production" } else { $null }
            tags = @([pscustomobject]@{ tag = "keep" })
            collections = @("COLL0001")
            relations = [pscustomobject]@{ "dc:relation" = "keep-relation" }
            dateModified = if ($AfterWrite) { "2026-07-29T12:00:00Z" } else { "2026-07-29T11:00:00Z" }
        }
    }
}

function Invoke-MaintenanceTarget {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Target,

        [Parameter(Mandatory = $true)]
        [object]$Scope
    )

    $readAdapter = {
        param($ParentItemKey)

        $script:ReadCount++
        Add-LiveAdapterCall `
            -Operation "read" `
            -Payload ([pscustomobject]@{
                parentItemKey = $ParentItemKey
                ordinal = $script:ReadCount
            })
        New-FakeLiveParent -AfterWrite ($script:ReadCount -gt 1)
    }
    $metadataHttpAdapter = {
        param($Uri)

        Add-LiveAdapterCall -Operation "query" -Payload ([pscustomobject]@{ uri = $Uri })
        [pscustomobject][ordered]@{
            statusCode = 200
            body = [pscustomobject][ordered]@{
                message = [pscustomobject][ordered]@{
                    type = "journal-article"
                    title = @("Production Wiring Paper")
                    author = @(
                        [pscustomobject][ordered]@{
                            given = "Ada"
                            family = "Lovelace"
                        }
                    )
                    DOI = "10.1000/production"
                    "published-print" = [pscustomobject][ordered]@{
                        "date-parts" = @(@(2025))
                    }
                    "container-title" = @("Formal Journal")
                    URL = "https://doi.org/10.1000/production"
                }
            }
        }
    }
    $mcpAdapter = {
        param($Arguments)

        $match = [regex]::Match([string]$Arguments.script, 'atob\("([^"]+)"\)')
        if (-not $match.Success) {
            throw "Fake MCP adapter could not find the encoded write request."
        }
        $payloadJson = [Text.Encoding]::UTF8.GetString(
            [Convert]::FromBase64String($match.Groups[1].Value)
        )
        Add-LiveAdapterCall -Operation "mcp" -Payload ($payloadJson | ConvertFrom-Json)
        $toolResult = [pscustomobject][ordered]@{
            mode = "write"
            description = $Arguments.description
            output = '{"status":"written","version":8}'
            itemsAffected = 1
        }
        [pscustomobject][ordered]@{
            result = [pscustomobject][ordered]@{
                isError = $false
                content = @(
                    [pscustomobject][ordered]@{
                        type = "text"
                        text = $toolResult | ConvertTo-Json -Depth 10 -Compress
                    }
                )
            }
        }
    }

    if ([string]$env:ZPU_LIVE_ADAPTER_SCENARIO -eq "rename-source-missing") {
        Remove-Item -LiteralPath ([string]$Target.path) -Force
    }

    & $script:ProductionModule {
        param($ResolvedTarget, $ResolvedScope, $Read, $MetadataHttp, $Mcp)
        Invoke-MaintenanceTarget `
            -Target $ResolvedTarget `
            -Scope $ResolvedScope `
            -ReadAdapter $Read `
            -MetadataHttpAdapter $MetadataHttp `
            -McpAdapter $Mcp
    } $Target $Scope $readAdapter $metadataHttpAdapter $mcpAdapter
}

Export-ModuleMember -Function Get-MaintenanceZoteroItem, Invoke-MaintenanceTarget
