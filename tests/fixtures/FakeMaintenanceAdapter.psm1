Set-StrictMode -Version Latest

function Get-FakeZoteroItemPair {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ParentKey,

        [Parameter(Mandatory = $true)]
        [string]$AttachmentKey
    )

    @(
        [pscustomobject]@{
            key = $ParentKey
            data = [pscustomobject]@{ itemType = "journalArticle"; title = "Fake paper $ParentKey" }
        },
        [pscustomobject]@{
            key = $AttachmentKey
            data = [pscustomobject]@{
                itemType = "attachment"
                parentItem = $ParentKey
                contentType = "application/pdf"
            }
        }
    )
}

function Get-MaintenanceZoteroItem {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Scope
    )

    if ($env:ZPU_FAKE_SCENARIO -eq "run-failure") {
        throw "Fake adapter could not enumerate targets."
    }
    $scenarioPairs = @{
        "target-blocked" = @(
            @("PARENT-BLOCKED", "A2B3C4D5"),
            @("PARENT-CONTINUED", "E6F7G8H9")
        )
        "progress-then-crash" = @(
            @("PARENT-CHANGED", "J2K3L4M5"),
            @("PARENT-CRASHED", "N6P7Q8R9")
        )
        "progress-then-invalid-result" = @(
            @("PARENT-VALID", "S2T3U4V5"),
            @("PARENT-INVALID", "W6X7Y8Z9")
        )
    }
    if ($scenarioPairs.ContainsKey([string]$env:ZPU_FAKE_SCENARIO)) {
        return @(
            foreach ($pair in $scenarioPairs[[string]$env:ZPU_FAKE_SCENARIO]) {
                Get-FakeZoteroItemPair -ParentKey $pair[0] -AttachmentKey $pair[1]
            }
        )
    }
    if ($env:ZPU_FAKE_SCENARIO -eq "non-pdf-attachment") {
        return @(
            [pscustomobject]@{
                key = "PARENT-NONPDF"
                data = [pscustomobject]@{ itemType = "webpage"; title = "Not a PDF" }
            },
            [pscustomobject]@{
                key = "Z2Y3X4W5"
                data = [pscustomobject]@{
                    itemType = "attachment"
                    parentItem = "PARENT-NONPDF"
                    contentType = "text/html"
                }
            }
        )
    }
    if ($env:ZPU_FAKE_SCENARIO -eq "orphan-attachment") {
        return [pscustomobject]@{
            key = "Z3X5V7T9"
            data = [pscustomobject]@{
                itemType = "attachment"
                parentItem = "PARENT-MISSING"
                contentType = "application/pdf"
            }
        }
    }
    if ($env:ZPU_FAKE_SCENARIO -eq "invalid-attachment-key") {
        return @(
            [pscustomobject]@{
                key = "PARENT-BADKEY"
                data = [pscustomobject]@{ itemType = "journalArticle"; title = "Unsafe key" }
            },
            [pscustomobject]@{
                key = "..\BAD"
                data = [pscustomobject]@{
                    itemType = "attachment"
                    parentItem = "PARENT-BADKEY"
                    contentType = "application/pdf"
                }
            }
        )
    }
    if ($env:ZPU_FAKE_SCENARIO -eq "multiple-parent-pdfs") {
        return @(
            Get-FakeZoteroItemPair -ParentKey "PARENT-MULTI" -AttachmentKey "R2T4V6X8"
            [pscustomobject]@{
                key = "S3U5W7Y9"
                data = [pscustomobject]@{
                    itemType = "attachment"
                    parentItem = "PARENT-MULTI"
                    contentType = "application/pdf"
                }
            }
        )
    }
    if ($env:ZPU_FAKE_SCENARIO -eq "all-mixed") {
        return @(
            Get-FakeZoteroItemPair -ParentKey "PARENT-GOOD" -AttachmentKey "A3C5E7G9"
            Get-FakeZoteroItemPair -ParentKey "PARENT-MISSING" -AttachmentKey "B2D4F6H8"
            Get-FakeZoteroItemPair -ParentKey "PARENT-CONFLICT" -AttachmentKey "J3L5N7Q9"
        )
    }
    if ($env:ZPU_FAKE_SCENARIO -eq "ambiguous-path") {
        return @(
            [pscustomobject]@{
                key = "PARENT-A"
                data = [pscustomobject]@{ itemType = "journalArticle"; title = "First fake paper" }
            },
            [pscustomobject]@{
                key = "STUVWXYZ"
                data = [pscustomobject]@{
                    itemType = "attachment"
                    parentItem = "PARENT-A"
                    contentType = "application/pdf"
                }
            },
            [pscustomobject]@{
                key = "PARENT-B"
                data = [pscustomobject]@{ itemType = "journalArticle"; title = "Second fake paper" }
            },
            [pscustomobject]@{
                key = "23456789"
                data = [pscustomobject]@{
                    itemType = "attachment"
                    parentItem = "PARENT-B"
                    contentType = "application/pdf"
                }
            }
        )
    }

    $parentKey = if ($Scope.selector -in @("PARENT9", "JKLMNPQR")) { "PARENT9" } else { "PARENT1" }
    $attachmentKey = if ($parentKey -eq "PARENT9") { "JKLMNPQR" } else { "ABCDEFGH" }
    @(
        [pscustomobject]@{
            key = $parentKey
            data = [pscustomobject]@{
                itemType = "journalArticle"
                title = "Fake paper"
            }
        },
        [pscustomobject]@{
            key = $attachmentKey
            data = [pscustomobject]@{
                itemType = "attachment"
                parentItem = $parentKey
                contentType = "application/pdf"
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
    switch ($env:ZPU_FAKE_SCENARIO) {
        "progress-then-invalid-result" {
            if ($Target.parentItemKey -eq "PARENT-INVALID") {
                return [pscustomobject][ordered]@{
                    status = "not-a-status"
                    actions = @()
                    issues = @()
                }
            }
            return [pscustomobject][ordered]@{
                status = "succeeded"
                actions = @(
                    [pscustomobject][ordered]@{
                        category = "modified"
                        kind = "fake_valid_progress"
                        target = $Target
                        before = [pscustomobject]@{ value = "before" }
                        after = [pscustomobject]@{ value = "after" }
                        evidence = @("fake:valid-progress")
                    }
                )
                issues = @()
            }
        }
        "progress-then-crash" {
            if ($Target.parentItemKey -eq "PARENT-CRASHED") {
                throw "Fake adapter crashed after prior progress."
            }
            return [pscustomobject][ordered]@{
                status = "succeeded"
                actions = @(
                    [pscustomobject][ordered]@{
                        category = "modified"
                        kind = "fake_progress"
                        target = $Target
                        before = [pscustomobject]@{ value = "before" }
                        after = [pscustomobject]@{ value = "after" }
                        evidence = @("fake:progress")
                    }
                )
                issues = @()
            }
        }
        "target-blocked" {
            if ($Target.parentItemKey -eq "PARENT-BLOCKED") {
                return [pscustomobject][ordered]@{
                    status = "failed"
                    actions = @()
                    issues = @(
                        [pscustomobject][ordered]@{
                            severity = "error"
                            code = "fake_target_blocked"
                            target = $Target
                            message = "The fake target is blocked by local evidence."
                            evidence = @("fake:conflict")
                        }
                    )
                }
            }
            return [pscustomobject][ordered]@{
                status = "succeeded"
                actions = @()
                issues = @()
            }
        }
        "inconsistent" {
            return [pscustomobject][ordered]@{
                status = "succeeded"
                actions = @()
                issues = @(
                    [pscustomobject][ordered]@{
                        severity = "error"
                        code = "fake_unresolved"
                        target = $Target
                        message = "This issue contradicts succeeded status."
                        evidence = @()
                    }
                )
            }
        }
        "target-failure" {
            throw "Fake target maintenance failed."
        }
        "partial" {
            return [pscustomobject][ordered]@{
                status = "partial"
                actions = @(
                    [pscustomobject][ordered]@{
                        category = "modified"
                        kind = "metadata_updated"
                        target = $Target
                        before = [pscustomobject]@{ DOI = $null }
                        after = [pscustomobject]@{ DOI = "10.0000/example" }
                        evidence = @("fake:exact-match")
                    }
                )
                issues = @(
                    [pscustomobject][ordered]@{
                        severity = "error"
                        code = "association_ambiguous"
                        target = $Target
                        message = "The fake association is ambiguous."
                        evidence = @("fake:a", "fake:b")
                    }
                )
            }
        }
        default {
            return [pscustomobject][ordered]@{
                status = "succeeded"
                actions = @()
                issues = @()
            }
        }
    }
}

Export-ModuleMember -Function Get-MaintenanceZoteroItem, Invoke-MaintenanceTarget
