Set-StrictMode -Version Latest

function Resolve-MaintenanceTarget {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Scope
    )

    if ($env:ZPU_FAKE_SCENARIO -eq "run-failure") {
        throw "Fake adapter could not enumerate targets."
    }
    if ($env:ZPU_FAKE_SCENARIO -eq "sparse-target") {
        return [pscustomobject][ordered]@{
            parentItemKey = "PARENT-SPARSE"
        }
    }
    if ($env:ZPU_FAKE_SCENARIO -eq "target-blocked") {
        return @(
            [pscustomobject][ordered]@{
                parentItemKey = "PARENT-BLOCKED"
                attachmentKey = "ATTACH-BLOCKED"
                path = Join-Path $Scope.paperRoot "blocked.pdf"
            },
            [pscustomobject][ordered]@{
                parentItemKey = "PARENT-CONTINUED"
                attachmentKey = "ATTACH-CONTINUED"
                path = Join-Path $Scope.paperRoot "continued.pdf"
            }
        )
    }
    if ($env:ZPU_FAKE_SCENARIO -eq "progress-then-crash") {
        return @(
            [pscustomobject][ordered]@{
                parentItemKey = "PARENT-CHANGED"
                attachmentKey = "ATTACH-CHANGED"
                path = Join-Path $Scope.paperRoot "changed.pdf"
            },
            [pscustomobject][ordered]@{
                parentItemKey = "PARENT-CRASHED"
                attachmentKey = "ATTACH-CRASHED"
                path = Join-Path $Scope.paperRoot "crashed.pdf"
            }
        )
    }
    if ($env:ZPU_FAKE_SCENARIO -eq "progress-then-invalid-result") {
        return @(
            [pscustomobject][ordered]@{
                parentItemKey = "PARENT-VALID"
                attachmentKey = "ATTACH-VALID"
                path = Join-Path $Scope.paperRoot "valid.pdf"
            },
            [pscustomobject][ordered]@{
                parentItemKey = "PARENT-INVALID"
                attachmentKey = "ATTACH-INVALID"
                path = Join-Path $Scope.paperRoot "invalid.pdf"
            }
        )
    }

    @(
        [pscustomobject][ordered]@{
            parentItemKey = if ($Scope.mode -eq "itemKey") { $Scope.selector } else { "PARENT1" }
            attachmentKey = "ATTACH1"
            path = if ($Scope.mode -eq "path") { $Scope.selector } else { Join-Path $Scope.paperRoot "paper.pdf" }
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

Export-ModuleMember -Function Resolve-MaintenanceTarget, Invoke-MaintenanceTarget
