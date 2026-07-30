Set-StrictMode -Version Latest

function Get-MaintenanceZoteroItem {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseSingularNouns",
        "",
        Justification = "Matches the private maintenance adapter contract."
    )]
    param([Parameter(Mandatory = $true)][object]$Scope)

    $null = $Scope
    @(
        [pscustomobject]@{
            key = "PARENT23"
            version = 1
            data = [pscustomobject]@{
                key = "PARENT23"
                itemType = "journalArticle"
                title = "Managed paper"
            }
        },
        [pscustomobject]@{
            key = "ATTACH23"
            version = 1
            data = [pscustomobject]@{
                key = "ATTACH23"
                itemType = "attachment"
                parentItem = "PARENT23"
                contentType = "application/pdf"
                filename = "Canonical.pdf"
            }
        }
    )
}

function Invoke-MaintenanceTarget {
    param(
        [Parameter(Mandatory = $true)][object]$Target,
        [Parameter(Mandatory = $true)][object]$Scope
    )

    $null = $Target
    $null = $Scope
    if ([string]$env:ZPU_PUBLIC_SCENARIO -eq "rename-collision") {
        return [pscustomobject][ordered]@{
            status = "failed"
            actions = @()
            issues = @(
                [pscustomobject][ordered]@{
                    severity = "error"
                    code = "rename_target_conflict"
                    target = $Target
                    message = "The canonical filename exists with different bytes."
                    evidence = @("fake-different-sha256")
                }
            )
        }
    }
    [pscustomobject][ordered]@{
        status = "succeeded"
        actions = @()
        issues = @()
    }
}

function Invoke-MaintenanceCleanup {
    param(
        [Parameter(Mandatory = $true)][object]$Scope,
        [Parameter(Mandatory = $true)][object[]]$Targets
    )

    $null = $Scope
    $null = $Targets
    $target = [pscustomobject][ordered]@{
        parentItemKey = "PARENT24"
        attachmentKey = "ATTACH24"
        path = $null
    }
    if ([string]$env:ZPU_PUBLIC_SCENARIO -ne "cleanup") {
        return [pscustomobject][ordered]@{
            status = "succeeded"
            target = $target
            actions = @()
            issues = @()
        }
    }

    $statePath = [string]$env:ZPU_PUBLIC_CLEANUP_STATE
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        return [pscustomobject][ordered]@{
            status = "succeeded"
            target = $target
            actions = @()
            issues = @()
        }
    }
    [IO.File]::WriteAllText($statePath, "completed", [Text.UTF8Encoding]::new($false))
    [pscustomobject][ordered]@{
        status = "succeeded"
        target = $target
        actions = @(
            [pscustomobject][ordered]@{
                category = "deleted"
                kind = "strict_duplicate_cleanup"
                target = $target
                before = [pscustomobject][ordered]@{
                    parentItemKeys = @("PARENT24")
                    attachmentKeys = @("ATTACH24")
                    storagePaths = @("storage\ATTACH24")
                    cachePaths = @("llm-for-zotero-mineru\2")
                    localPaths = @("duplicate.pdf")
                }
                after = $null
                evidence = @("fake-completed-transaction")
            }
        )
        issues = @()
    }
}

Export-ModuleMember -Function `
    Get-MaintenanceZoteroItem, `
    Invoke-MaintenanceTarget, `
    Invoke-MaintenanceCleanup
