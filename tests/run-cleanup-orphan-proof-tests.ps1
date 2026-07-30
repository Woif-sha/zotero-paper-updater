[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module `
    (Join-Path $repoRoot "scripts\ZoteroPaperUpdater.DuplicateCleanupLive.psm1") `
    -Force `
    -DisableNameChecking

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) (
    "zpu-orphan-proof-" + [guid]::NewGuid().ToString("N")
)
$cacheRoot = Join-Path $tempRoot "llm-for-zotero-mineru"
$paperRoot = Join-Path $tempRoot "papers"
$storageRoot = Join-Path $tempRoot "storage"
$passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:passed++
}

function Assert-OrphanBlocked {
    param([object[]]$Items, [string]$ExpectedMessage)

    $blocked = $false
    $actualMessage = $null
    try {
        Assert-LiveCleanupClosure `
            -Plan $plan `
            -Scope $scope `
            -Items $Items `
            -CacheRoot $cacheRoot
    }
    catch {
        $actualMessage = $_.Exception.Message
        $blocked = $_.Exception.Message -match $ExpectedMessage
    }
    Assert-True $blocked "orphan proof should block $ExpectedMessage (actual: $actualMessage)"
}

try {
    [IO.Directory]::CreateDirectory($cacheRoot) | Out-Null
    [IO.Directory]::CreateDirectory($paperRoot) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $storageRoot "KEEP-ATTACH")) | Out-Null
    $pdfBytes = [Text.Encoding]::ASCII.GetBytes("%PDF-retain")
    [IO.File]::WriteAllBytes((Join-Path $storageRoot "KEEP-ATTACH\paper.pdf"), $pdfBytes)
    [IO.File]::WriteAllBytes((Join-Path $paperRoot "paper.pdf"), $pdfBytes)
    $scope = [pscustomobject]@{
        zoteroDataDir = $tempRoot
        paperRoot = $paperRoot
    }
    $retainCache = Join-Path $cacheRoot "retain"
    [IO.Directory]::CreateDirectory($retainCache) | Out-Null
    $retainMarkdown = "# retained"
    [IO.File]::WriteAllText((Join-Path $retainCache "full.md"), $retainMarkdown)
    [IO.File]::WriteAllText(
        (Join-Path $retainCache "manifest.json"),
        ([pscustomobject]@{
            totalChars = $retainMarkdown.Length
            sections = @()
            figureBlocks = @()
        } | ConvertTo-Json -Depth 5)
    )
    [IO.File]::WriteAllText(
        (Join-Path $retainCache "_llm_source.json"),
        '{"kind":"llm-for-zotero/mineru-cache-source","version":2,"attachmentKey":"KEEP-ATTACH","parentItemKey":"KEEP-PARENT","parsedAt":"2026-07-30T00:00:00Z"}'
    )
    $plan = [pscustomobject]@{
        retain = [pscustomobject]@{
            parent = [pscustomobject]@{ key = "KEEP-PARENT" }
            attachment = [pscustomobject]@{ key = "KEEP-ATTACH" }
        }
        deleteKeys = @("DROP-PARENT", "DROP-ATTACH")
        remove = [pscustomobject]@{
            parent = [pscustomobject]@{
                childKeys = @("DROP-NOTE")
                notes = @("DROP-NOTE")
                unknownChildren = @("DROP-CHILD")
            }
        }
    }
    $retainItems = @(
        [pscustomobject]@{
            key = "KEEP-PARENT"
            version = 2
            data = [pscustomobject]@{ itemType = "journalArticle" }
        },
        [pscustomobject]@{
            key = "KEEP-ATTACH"
            version = 3
            data = [pscustomobject]@{
                itemType = "attachment"
                parentItem = "KEEP-PARENT"
                title = "Version of Record"
            }
        }
    )
    $plan.retain = ConvertTo-LiveCleanupSide `
        -Scope $scope `
        -Parent $retainItems[0] `
        -Attachment $retainItems[1] `
        -Items $retainItems
    Assert-OrphanBlocked `
        -Items (@($retainItems) + @([pscustomobject]@{
            key = "DROP-NOTE"
            data = [pscustomobject]@{ itemType = "note" }
        })) `
        -ExpectedMessage "losing Zotero key"

    Assert-OrphanBlocked `
        -Items (@($retainItems) + @([pscustomobject]@{
            key = "KEEP-OTHER"
            data = [pscustomobject]@{
                relations = [pscustomobject]@{
                    "dc:relation" = "http://zotero.org/users/1/items/DROP-PARENT"
                }
            }
        })) `
        -ExpectedMessage "still points to losing key"

    $sourceDirectory = Join-Path $cacheRoot "unrelated-directory"
    [IO.Directory]::CreateDirectory($sourceDirectory) | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $sourceDirectory "_llm_source.json"),
        '{"attachmentKey":"DROP-ATTACH","parentItemKey":"DROP-PARENT"}',
        [Text.UTF8Encoding]::new($false)
    )
    Assert-OrphanBlocked -Items $retainItems -ExpectedMessage "MinerU provenance"

    Remove-Item -LiteralPath $sourceDirectory -Recurse -Force
    Assert-OrphanBlocked `
        -Items @($retainItems | Where-Object { $_.key -ne "KEEP-PARENT" }) `
        -ExpectedMessage "retained Zotero parent"
    Assert-LiveCleanupClosure -Plan $plan -Scope $scope -Items (@($retainItems) + @([pscustomobject]@{
        key = "KEEP-OTHER"
        data = [pscustomobject]@{ relations = [pscustomobject]@{} }
    })) -CacheRoot $cacheRoot
    Assert-True $true "closed cleanup graph should pass"

    [IO.Directory]::CreateDirectory((Join-Path $storageRoot "DROP-ATTACH")) | Out-Null
    $dropBytes = [Text.Encoding]::ASCII.GetBytes("%PDF-drop")
    [IO.File]::WriteAllBytes((Join-Path $storageRoot "DROP-ATTACH\drop.pdf"), $dropBytes)
    [IO.File]::WriteAllBytes((Join-Path $paperRoot "drop.pdf"), $dropBytes)
    $dropCache = Join-Path $cacheRoot "drop"
    [IO.Directory]::CreateDirectory($dropCache) | Out-Null
    $dropMarkdown = "# drop"
    [IO.File]::WriteAllText((Join-Path $dropCache "full.md"), $dropMarkdown)
    [IO.File]::WriteAllText(
        (Join-Path $dropCache "manifest.json"),
        ([pscustomobject]@{
            totalChars = $dropMarkdown.Length
            sections = @()
            figureBlocks = @()
        } | ConvertTo-Json -Depth 5)
    )
    [IO.File]::WriteAllText(
        (Join-Path $dropCache "_llm_source.json"),
        '{"kind":"llm-for-zotero/mineru-cache-source","version":2,"attachmentKey":"DROP-ATTACH","parentItemKey":"DROP-PARENT","parsedAt":"2026-07-30T00:00:00Z"}'
    )
    $trashItems = @($retainItems) + @(
        [pscustomobject]@{
            key = "DROP-PARENT"
            version = 8
            data = [pscustomobject]@{
                itemType = "journalArticle"
                DOI = "10.1000/drop"
                title = "Drop"
                creators = @()
                relations = [pscustomobject]@{}
                tags = @()
                collections = @()
            }
        },
        [pscustomobject]@{
            key = "DROP-ATTACH"
            version = 5
            data = [pscustomobject]@{
                itemType = "attachment"
                parentItem = "DROP-PARENT"
                title = "Version of Record"
                relations = [pscustomobject]@{}
                tags = @()
            }
        }
    )
    $liveDropSide = ConvertTo-LiveCleanupSide `
        -Scope $scope `
        -Parent $trashItems[-2] `
        -Attachment $trashItems[-1] `
        -Items $trashItems
    $expectedDrop = [Management.Automation.PSSerializer]::Deserialize(
        [Management.Automation.PSSerializer]::Serialize($liveDropSide, 20)
    )
    $expectedDrop.parent.version--
    $expectedDrop.attachment.version--
    $trashPlan = [pscustomobject]@{
        remove = $expectedDrop
        deleteKeys = @("DROP-PARENT", "DROP-ATTACH")
    }
    Assert-LiveTrashedCleanupEvidence `
        -Plan $trashPlan `
        -Scope $scope `
        -Items $trashItems
    Assert-True $true "unchanged Trash snapshot should pass"
    $trashDrift = $false
    try {
        Assert-LiveTrashedCleanupEvidence `
            -Plan $trashPlan `
            -Scope $scope `
            -Items (@($trashItems) + @([pscustomobject]@{
                key = "NEW-NOTE"
                version = 1
                data = [pscustomobject]@{
                    itemType = "note"
                    parentItem = "DROP-PARENT"
                }
            }))
    }
    catch {
        $trashDrift = [string]$_.Exception.Data["ZpuIssueCode"] -eq
            "cleanup_drift_zotero_state"
    }
    Assert-True $trashDrift "new Trash note should be a typed pre-purge drift"

    $invalidPathTyped = $false
    try {
        $null = Get-LiveCleanupAssetEvidence `
            -Plan ([pscustomobject]@{ scope = $scope }) `
            -ExpectedEvidence @([pscustomobject]@{
                side = "remove"
                kind = "local"
                value = [pscustomobject]@{ path = "bad$([char]0)path.pdf" }
            })
    }
    catch {
        $invalidPathTyped = [string]$_.Exception.Data["ZpuIssueCode"] -eq
            "cleanup_drift_path"
    }
    Assert-True $invalidPathTyped "invalid descriptor paths should be typed at the live boundary"

    $outsideStorage = Join-Path $tempRoot "outside-storage"
    [IO.Directory]::CreateDirectory($outsideStorage) | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $outsideStorage "linked.pdf"), $dropBytes)
    $storageLink = Join-Path $storageRoot "linked"
    $null = New-Item -ItemType Junction -Path $storageLink -Target $outsideStorage
    $storageReparseTyped = $false
    try {
        $null = Get-LiveCleanupAssetEvidence `
            -Plan ([pscustomobject]@{ scope = $scope }) `
            -ExpectedEvidence @([pscustomobject]@{
                side = "remove"
                kind = "storage"
                value = [pscustomobject]@{
                    path = $storageRoot
                    pdfPath = Join-Path $storageLink "linked.pdf"
                    sha256 = "irrelevant"
                }
            })
    }
    catch {
        $storageReparseTyped = [string]$_.Exception.Data["ZpuIssueCode"] -eq
            "cleanup_drift_path"
    }
    Assert-True $storageReparseTyped "storage PDF reparse paths should be typed at the live boundary"

    $invalidStoragePdfTyped = $false
    try {
        $null = Get-LiveCleanupAssetEvidence `
            -Plan ([pscustomobject]@{ scope = $scope }) `
            -ExpectedEvidence @([pscustomobject]@{
                side = "remove"
                kind = "storage"
                value = [pscustomobject]@{
                    path = $storageRoot
                    pdfPath = "bad$([char]0)storage.pdf"
                    sha256 = "irrelevant"
                }
            })
    }
    catch {
        $invalidStoragePdfTyped = [string]$_.Exception.Data["ZpuIssueCode"] -eq
            "cleanup_drift_path"
    }
    Assert-True $invalidStoragePdfTyped "invalid storage PDF paths should be typed"

    $localDirectoryTyped = $false
    try {
        $null = Get-LiveCleanupAssetEvidence `
            -Plan ([pscustomobject]@{ scope = $scope }) `
            -ExpectedEvidence @([pscustomobject]@{
                side = "remove"
                kind = "local"
                value = [pscustomobject]@{
                    path = $paperRoot
                    sha256 = "irrelevant"
                }
            })
    }
    catch {
        $localDirectoryTyped = [string]$_.Exception.Data["ZpuIssueCode"] -eq
            "cleanup_drift_path"
    }
    Assert-True $localDirectoryTyped "local directories should be typed as path drift"

    $replacement = [Text.Encoding]::ASCII.GetBytes("%PDF-replaced")
    [IO.File]::WriteAllBytes((Join-Path $storageRoot "KEEP-ATTACH\paper.pdf"), $replacement)
    [IO.File]::WriteAllBytes((Join-Path $paperRoot "paper.pdf"), $replacement)
    $retainedHashBlocked = $false
    try {
        Assert-LiveCleanupClosure `
            -Plan $plan `
            -Scope $scope `
            -Items $retainItems `
            -CacheRoot $cacheRoot
    }
    catch {
        $retainedHashBlocked = $_.Exception.Message -match "hash drifted"
    }
    Assert-True $retainedHashBlocked "completed closure should reject replaced retained content"

    Write-Output "All $passed cleanup-orphan-proof assertions passed."
}
finally {
    $resolved = [IO.Path]::GetFullPath($tempRoot)
    $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolved.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
