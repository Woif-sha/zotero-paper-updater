[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) `
    "scripts\ZoteroPaperUpdater.ZoteroWriter.psm1"
$commonPath = Join-Path (Split-Path -Parent $PSScriptRoot) `
    "scripts\ZoteroPaperUpdater.Common.psm1"
Import-Module $commonPath -Force -DisableNameChecking
Import-Module $modulePath -Force -DisableNameChecking

$before = [pscustomobject][ordered]@{
    key = "PARENT22"
    version = 7
    data = [pscustomobject][ordered]@{
        key = "PARENT22"
        version = 7
        itemType = "journalArticle"
        title = "Paper"
        date = "2024"
        tags = @([pscustomobject]@{ tag = "keep" })
    }
}
$readCount = 0
$capturedScript = $null
$result = Invoke-ZoteroMetadataWrite `
    -WriteRequest ([pscustomobject][ordered]@{
        parentItemKey = "PARENT22"
        expectedVersion = 7
        fields = [pscustomobject]@{ date = "2025" }
    }) `
    -BeforeLiveItem $before `
    -ReadAdapter {
        param($Key)
        $null = $Key
        $script:readCount++
        [pscustomobject][ordered]@{
            key = "PARENT22"
            version = 9
            data = [pscustomobject][ordered]@{
                key = "PARENT22"
                version = 9
                itemType = "journalArticle"
                title = "Paper"
                date = "2024"
                tags = @([pscustomobject]@{ tag = "keep" })
            }
        }
    } `
    -McpAdapter {
        param($Arguments)
        $script:capturedScript = $Arguments.script
        $toolResult = [pscustomobject][ordered]@{
            mode = "write"
            description = $Arguments.description
            output = '{"status":"version_conflict","actualVersion":9}'
            itemsAffected = 0
        }
        [pscustomobject]@{
            result = [pscustomobject]@{
                isError = $false
                content = @(
                    [pscustomobject]@{
                        type = "text"
                        text = $toolResult | ConvertTo-Json -Depth 10 -Compress
                    }
                )
            }
        }
    }

if ($result.status -ne "version_conflict" -or $result.actualVersion -ne 9) {
    throw "Writer did not preserve the MCP business-level version conflict."
}
if ($readCount -ne 1) {
    throw "Writer should reread the live item once after a version conflict."
}
if ($capturedScript -notmatch "getUsedFields") {
    throw "Writer should preflight source-absent fields before an item type change."
}
if ($capturedScript.IndexOf("getUsedFields") -gt $capturedScript.IndexOf("env.snapshot")) {
    throw "Writer type-schema preflight must happen before the first mutation snapshot."
}
if (-not (Test-DeepValueEqual -Left @{ relation = "kept" } -Right @{ relation = "kept" })) {
    throw "Shared deep comparison should accept equal dictionary-backed user state."
}
if (Test-DeepValueEqual -Left @{ relation = "kept" } -Right @{ relation = "changed" }) {
    throw "Shared deep comparison should detect changed dictionary-backed user state."
}
Write-Output "All 6 Zotero-writer assertions passed."
