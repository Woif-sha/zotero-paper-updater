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

$consolidationReadCount = 0
$consolidationScript = $null
$consolidationResult = Invoke-ZoteroConsolidationWrite `
    -Decision ([pscustomobject][ordered]@{
        status = "eligible"
        retainedAttachment = [pscustomobject]@{ key = "ATTACH22" }
        parentWriteRequest = [pscustomobject][ordered]@{
            parentItemKey = "PARENT11"
            expectedVersion = 7
            tags = @("keep", "merged")
            collections = @("3", "4")
            relations = [pscustomobject]@{ "dc:relation" = @("PARENT33") }
        }
        attachmentWriteRequest = [pscustomobject][ordered]@{
            attachmentKey = "ATTACH22"
            expectedVersion = 3
            parentItemKey = "PARENT11"
        }
        inboundRelationWrites = @()
    }) `
    -ReadAdapter {
        param($Key)
        $script:consolidationReadCount++
        if ($Key -eq "PARENT11") {
            if ($script:consolidationReadCount -le 2) {
                return [pscustomobject]@{
                    key = $Key
                    version = 7
                    data = [pscustomobject][ordered]@{
                        tags = @("keep")
                        collections = @("3")
                        relations = [pscustomobject]@{}
                    }
                }
            }
            return [pscustomobject]@{
                key = $Key
                version = 8
                data = [pscustomobject][ordered]@{
                    tags = @("keep", "merged")
                    collections = @("3", "4")
                    relations = [pscustomobject]@{ "dc:relation" = @("PARENT33") }
                }
            }
        }
        if ($script:consolidationReadCount -le 2) {
            return [pscustomobject]@{
                key = $Key
                version = 3
                data = [pscustomobject]@{ parentItem = "PARENT22" }
            }
        }
        [pscustomobject]@{
            key = $Key
            version = 4
            data = [pscustomobject]@{ parentItem = "PARENT11" }
        }
    } `
    -McpAdapter {
        param($Arguments)
        $script:consolidationScript = $Arguments.script
        $toolResult = [pscustomobject][ordered]@{
            output = '{"status":"written","version":8}'
            itemsAffected = 2
        }
        [pscustomobject]@{
            result = [pscustomobject]@{
                isError = $false
                content = @([pscustomobject]@{
                    type = "text"
                    text = $toolResult | ConvertTo-Json -Compress
                })
            }
        }
    }
if ($consolidationResult.status -ne "written") {
    throw "Consolidation writer should report a verified write."
}
if ($consolidationReadCount -ne 4) {
    throw "Consolidation writer should preflight and reread every touched existing item."
}
if ($consolidationScript -notmatch "expectedVersions" -or
    $consolidationScript -notmatch "executeTransaction" -or
    $consolidationScript -notmatch "env.snapshot") {
    throw "Consolidation writer must version-check and snapshot all mutations in one transaction."
}

$conflictMcpCalls = 0
$conflictResult = Invoke-ZoteroConsolidationWrite `
    -Decision ([pscustomobject][ordered]@{
        status = "eligible"
        retainedAttachment = [pscustomobject]@{ key = "ATTACH11" }
        parentWriteRequest = [pscustomobject][ordered]@{
            parentItemKey = "PARENT11"
            expectedVersion = 7
            tags = @("merged")
            collections = @()
            relations = [pscustomobject]@{}
        }
        attachmentWriteRequest = $null
        inboundRelationWrites = @()
    }) `
    -ReadAdapter {
        param($Key)
        [pscustomobject]@{
            key = $Key
            version = 8
            data = [pscustomobject]@{
                tags = @("old")
                collections = @()
                relations = [pscustomobject]@{}
            }
        }
    } `
    -McpAdapter {
        param($Arguments)
        $null = $Arguments
        $script:conflictMcpCalls++
        throw "must not be called"
    }
if ($conflictResult.status -ne "version_conflict" -or $conflictMcpCalls -ne 0) {
    throw "A consolidation version drift must block before the MCP mutation."
}

$relationReadCount = 0
$relationVerificationFailed = $false
try {
    $null = Invoke-ZoteroConsolidationWrite `
        -Decision ([pscustomobject][ordered]@{
            status = "eligible"
            retainedAttachment = [pscustomobject]@{ key = "ATTACH11" }
            parentWriteRequest = [pscustomobject][ordered]@{
                parentItemKey = "PARENT11"
                expectedVersion = 7
                tags = @()
                collections = @()
                relations = [pscustomobject]@{}
            }
            attachmentWriteRequest = $null
            inboundRelationWrites = @([pscustomobject]@{
                sourceKey = "PARENT33"
                expectedVersion = 4
                predicate = "dc:relation"
                oldTargetKey = "zotero://select/library/items/PARENT22"
                newTargetKey = "zotero://select/library/items/PARENT11"
            })
        }) `
        -ReadAdapter {
            param($Key)
            $script:relationReadCount++
            if ($Key -eq "PARENT11") {
                return [pscustomobject]@{
                    key = $Key
                    version = if ($script:relationReadCount -le 2) { 7 } else { 8 }
                    data = [pscustomobject]@{
                        tags = @()
                        collections = @()
                        relations = [pscustomobject]@{}
                    }
                }
            }
            [pscustomobject]@{
                key = $Key
                version = if ($script:relationReadCount -le 2) { 4 } else { 5 }
                data = [pscustomobject]@{
                    relations = [pscustomobject]@{
                        "dc:relation" = @("zotero://select/library/items/PARENT22")
                    }
                }
            }
        } `
        -McpAdapter {
            param($Arguments)
            $null = $Arguments
            $toolResult = [pscustomobject]@{ output = '{"status":"written","version":8}' }
            [pscustomobject]@{
                result = [pscustomobject]@{
                    isError = $false
                    content = @([pscustomobject]@{
                        type = "text"
                        text = $toolResult | ConvertTo-Json -Compress
                    })
                }
            }
        }
}
catch {
    $relationVerificationFailed = $_.Exception.Message -match "inbound relation"
}
if (-not $relationVerificationFailed) {
    throw "A dangling inbound relation must fail post-write verification."
}
Write-Output "All 14 Zotero-writer assertions passed."
