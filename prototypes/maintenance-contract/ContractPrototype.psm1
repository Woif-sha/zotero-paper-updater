Set-StrictMode -Version Latest

function New-PrototypeScope {
    param(
        [ValidateSet("all", "itemKey", "path")]
        [string]$Mode,

        [string]$Value
    )

    [pscustomobject][ordered]@{
        mode = $Mode
        selector = if ($Mode -eq "all") { $null } else { $Value }
        paperRoot = "E:\paper"
        zoteroDataDir = "E:\ZoteroData"
    }
}

function New-PrototypeTarget {
    param(
        [string]$ParentItemKey = "PARENT1",
        [string]$AttachmentKey = "ATTACH1",
        [string]$Path = "E:\paper\Example Paper.pdf"
    )

    [pscustomobject][ordered]@{
        parentItemKey = $ParentItemKey
        attachmentKey = $AttachmentKey
        path = $Path
    }
}

function New-PrototypeAction {
    param(
        [ValidateSet("modified", "deleted", "renamed", "repaired")]
        [string]$Category,

        [string]$Kind,

        [object]$Target,

        [object]$Before,

        [object]$After,

        [string[]]$Evidence
    )

    [pscustomobject][ordered]@{
        category = $Category
        kind = $Kind
        target = $Target
        before = $Before
        after = $After
        evidence = @($Evidence)
    }
}

function New-PrototypeIssue {
    param(
        [ValidateSet("warning", "error")]
        [string]$Severity,

        [string]$Code,

        [object]$Target,

        [string]$Message,

        [string[]]$Evidence
    )

    [pscustomobject][ordered]@{
        severity = $Severity
        code = $Code
        target = $Target
        message = $Message
        evidence = @($Evidence)
    }
}

function New-PrototypeItemResult {
    param(
        [ValidateSet("succeeded", "partial", "failed")]
        [string]$Status,

        [object]$Target,

        [object[]]$Actions,

        [object[]]$Issues
    )

    [pscustomobject][ordered]@{
        status = $Status
        changed = @($Actions).Count -gt 0
        target = $Target
        actions = @($Actions)
        issues = @($Issues)
    }
}

function New-PrototypeMaintenanceResult {
    param(
        [ValidateSet("unchanged", "modified", "mixed", "failed")]
        [string]$Scenario,

        [ValidateSet("all", "itemKey", "path")]
        [string]$ScopeMode
    )

    $scopeValue = switch ($ScopeMode) {
        "itemKey" { "PARENT1" }
        "path" { "E:\paper\Example Paper.pdf" }
        default { $null }
    }
    $scope = New-PrototypeScope -Mode $ScopeMode -Value $scopeValue
    $target = New-PrototypeTarget
    $items = @()
    $runIssues = @()

    switch ($Scenario) {
        "unchanged" {
            $items = @(
                New-PrototypeItemResult -Status "succeeded" -Target $target -Actions @() -Issues @()
            )
        }
        "modified" {
            $actions = @(
                New-PrototypeAction `
                    -Category "modified" `
                    -Kind "metadata_updated" `
                    -Target $target `
                    -Before ([pscustomobject]@{ date = ""; publicationTitle = "" }) `
                    -After ([pscustomobject]@{ date = "2025"; publicationTitle = "Example Journal" }) `
                    -Evidence @("https://doi.org/10.0000/example")
                New-PrototypeAction `
                    -Category "renamed" `
                    -Kind "local_pdf_renamed" `
                    -Target $target `
                    -Before ([pscustomobject]@{ path = "E:\paper\download.pdf" }) `
                    -After ([pscustomobject]@{ path = "E:\paper\Example Paper.pdf" }) `
                    -Evidence @("sha256:EXAMPLE")
                New-PrototypeAction `
                    -Category "repaired" `
                    -Kind "cache_provenance_repaired" `
                    -Target $target `
                    -Before ([pscustomobject]@{ parentItemKey = "STALE1" }) `
                    -After ([pscustomobject]@{ parentItemKey = "PARENT1" }) `
                    -Evidence @("unique attachmentKey ATTACH1")
            )
            $items = @(
                New-PrototypeItemResult -Status "succeeded" -Target $target -Actions $actions -Issues @()
            )
        }
        "mixed" {
            $duplicateTarget = New-PrototypeTarget `
                -ParentItemKey "DUPLICATE1" `
                -AttachmentKey "DUPATTACH1" `
                -Path "E:\paper\duplicate.pdf"
            $actions = @(
                New-PrototypeAction `
                    -Category "modified" `
                    -Kind "metadata_updated" `
                    -Target $target `
                    -Before ([pscustomobject]@{ DOI = "" }) `
                    -After ([pscustomobject]@{ DOI = "10.0000/example" }) `
                    -Evidence @("https://doi.org/10.0000/example")
                New-PrototypeAction `
                    -Category "deleted" `
                    -Kind "duplicate_paper_deleted" `
                    -Target $duplicateTarget `
                    -Before ([pscustomobject]@{
                        retainedParentItemKey = "PARENT1"
                        artifacts = @(
                            "Zotero item DUPLICATE1",
                            "Zotero attachment DUPATTACH1",
                            "E:\paper\duplicate.pdf",
                            "E:\ZoteroData\llm-for-zotero-mineru\99"
                        )
                    }) `
                    -After $null `
                    -Evidence @("exact DOI match", "same ordered creators")
            )
            $issues = @(
                New-PrototypeIssue `
                    -Severity "warning" `
                    -Code "metadata_unavailable" `
                    -Target $target `
                    -Message "Pages remain unavailable after checking authoritative sources." `
                    -Evidence @("https://publisher.example/paper")
                New-PrototypeIssue `
                    -Severity "error" `
                    -Code "association_ambiguous" `
                    -Target $target `
                    -Message "Two local PDFs match the attachment hash; no association was changed." `
                    -Evidence @("E:\paper\copy-a.pdf", "E:\paper\copy-b.pdf")
            )
            $items = @(
                New-PrototypeItemResult -Status "partial" -Target $target -Actions $actions -Issues $issues
            )
        }
        "failed" {
            $runIssues = @(
                New-PrototypeIssue `
                    -Severity "error" `
                    -Code "zotero_unreachable" `
                    -Target $null `
                    -Message "The maintenance run could not inspect any target because Zotero was unavailable." `
                    -Evidence @("http://127.0.0.1:23119")
            )
        }
    }

    $allActions = @($items | ForEach-Object { $_.actions })
    $allItemIssues = @($items | ForEach-Object { $_.issues })
    $allIssues = @($runIssues) + @($allItemIssues)
    $status = if ($Scenario -eq "failed") {
        "failed"
    }
    elseif (@($items | Where-Object { $_.status -eq "partial" }).Count -gt 0) {
        "partial"
    }
    else {
        "succeeded"
    }

    [pscustomobject][ordered]@{
        schemaVersion = 1
        runId = [guid]::NewGuid().ToString()
        startedAt = (Get-Date).ToUniversalTime().ToString("o")
        completedAt = (Get-Date).ToUniversalTime().ToString("o")
        status = $status
        changed = $allActions.Count -gt 0
        scope = $scope
        summary = [pscustomobject][ordered]@{
            targetCount = $items.Count
            succeededCount = @($items | Where-Object { $_.status -eq "succeeded" }).Count
            partialCount = @($items | Where-Object { $_.status -eq "partial" }).Count
            failedCount = @($items | Where-Object { $_.status -eq "failed" }).Count
            actionCount = $allActions.Count
            unresolvedCount = $allIssues.Count
            actionsByCategory = [pscustomobject][ordered]@{
                modified = @($allActions | Where-Object { $_.category -eq "modified" }).Count
                deleted = @($allActions | Where-Object { $_.category -eq "deleted" }).Count
                renamed = @($allActions | Where-Object { $_.category -eq "renamed" }).Count
                repaired = @($allActions | Where-Object { $_.category -eq "repaired" }).Count
            }
        }
        results = @($items)
        issues = @($runIssues)
    }
}

Export-ModuleMember -Function New-PrototypeMaintenanceResult
