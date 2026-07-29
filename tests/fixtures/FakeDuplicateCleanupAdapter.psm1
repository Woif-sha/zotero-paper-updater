Set-StrictMode -Version Latest

function Add-CleanupCall {
    param([Parameter(Mandatory = $true)][string]$Value)

    [IO.File]::AppendAllText(
        $env:ZPU_CLEANUP_CALL_LOG,
        $Value + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
}

function Get-MaintenanceZoteroItem {
    param([Parameter(Mandatory = $true)][object]$Scope)

    $null = $Scope
    @(
        [pscustomobject]@{
            key = "PRNT1111"
            data = [pscustomobject]@{ itemType = "journalArticle"; DOI = "10.1000/run" }
        },
        [pscustomobject]@{
            key = "ATTACH33"
            data = [pscustomobject]@{
                itemType = "attachment"; parentItem = "PRNT1111"; contentType = "application/pdf"
            }
        },
        [pscustomobject]@{
            key = "PRNT2222"
            data = [pscustomobject]@{ itemType = "journalArticle"; DOI = "10.1000/run" }
        },
        [pscustomobject]@{
            key = "ATTACH44"
            data = [pscustomobject]@{
                itemType = "attachment"; parentItem = "PRNT2222"; contentType = "application/pdf"
            }
        }
    )
}

function Invoke-MaintenanceTarget {
    param(
        [Parameter(Mandatory = $true)][object]$Target,
        [Parameter(Mandatory = $true)][object]$Scope
    )

    $null = $Scope
    Add-CleanupCall -Value "target:$($Target.parentItemKey)"
    [pscustomobject][ordered]@{ status = "succeeded"; actions = @(); issues = @() }
}

function Invoke-MaintenanceCleanup {
    param(
        [Parameter(Mandatory = $true)][object]$Scope,
        [Parameter(Mandatory = $true)][object[]]$Targets
    )

    $null = $Scope
    Add-CleanupCall -Value "cleanup:$($Targets.Count)"
    $removed = $Targets | Where-Object { $_.parentItemKey -eq "PRNT2222" } | Select-Object -First 1
    [pscustomobject][ordered]@{
        target = $Targets[0]
        status = "succeeded"
        actions = @(
            [pscustomobject][ordered]@{
                category = "deleted"
                kind = "strict_duplicate_cleanup"
                target = $Targets[0]
                before = [pscustomobject][ordered]@{
                    parent = [pscustomobject]@{ key = $removed.parentItemKey }
                    attachment = [pscustomobject]@{ key = $removed.attachmentKey }
                    storage = [pscustomobject]@{ path = $removed.storagePath }
                    cache = [pscustomobject]@{ path = "cache-22" }
                    local = [pscustomobject]@{ path = $removed.path }
                }
                after = $null
                evidence = @("transaction:v1")
            }
        )
        issues = @()
    }
}

Export-ModuleMember -Function `
    Get-MaintenanceZoteroItem, `
    Invoke-MaintenanceTarget, `
    Invoke-MaintenanceCleanup
