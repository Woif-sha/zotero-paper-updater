Set-StrictMode -Version Latest

function Get-CompatibilityPolicy {
    [CmdletBinding()]
    param()

    [pscustomobject][ordered]@{
        publicEntry = [pscustomobject][ordered]@{
            script = "scripts/maintain-library.ps1"
            modes = @(
                "no selector -> full library",
                "-ItemKey <key> -> one managed Zotero item",
                "-Path <pdf> -> one managed local PDF"
            )
            optionalOverrides = @("-PaperRoot", "-ZoteroDataDir")
            selectorRule = "-ItemKey and -Path are mutually exclusive"
            output = "schema-versioned JSON on stdout"
            exitCodes = [pscustomobject][ordered]@{
                succeeded = 0
                failed = 1
                partial = 2
            }
        }
        compatibilityBoundary = "Preserve maintenance behavior and the new JSON contract, not legacy script CLIs or their JSON shapes."
        legacyInterfaces = @(
            [pscustomobject][ordered]@{
                interface = "scripts/resolve-paper-md.ps1"
                decision = "internalize"
                retainedCapability = "unique ItemKey-to-parent/attachment/cache resolution"
                compatibilityPromise = "none"
            },
            [pscustomobject][ordered]@{
                interface = "scripts/audit-paper-links.ps1"
                decision = "internalize"
                retainedCapability = "mapping, hash, filename-collision, and ambiguity checks"
                compatibilityPromise = "none"
            },
            [pscustomobject][ordered]@{
                interface = "scripts/check-llm-for-zotero-version.ps1"
                decision = "internalize"
                retainedCapability = "runtime preflight when a maintenance action depends on MinerU"
                compatibilityPromise = "none"
            },
            [pscustomobject][ordered]@{
                interface = "scripts/invoke-llm-for-zotero-mcp.ps1"
                decision = "internalize"
                retainedCapability = "authenticated llm-for-zotero MCP transport"
                compatibilityPromise = "none"
            },
            [pscustomobject][ordered]@{
                interface = "legacy reading, note, and metadata-gap behaviors"
                decision = "delete"
                retainedCapability = "none"
                compatibilityPromise = "none"
            }
        )
        removedPublicOptions = @(
            "-AllowIncomplete",
            "-SkipHash",
            "-SkipApi",
            "-RequireAllCaches",
            "-ZoteroApiBase",
            "legacy resolver positional arguments",
            "legacy per-script JSON fields"
        )
    }
}

function New-ExpectedResult {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("succeeded", "partial", "failed")]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [bool]$Changed,

        [string[]]$ActionCategories = @(),

        [string[]]$IssueCodes = @(),

        [string[]]$Invariants = @()
    )

    $exitCode = switch ($Status) {
        "succeeded" { 0 }
        "partial" { 2 }
        "failed" { 1 }
    }

    [pscustomobject][ordered]@{
        status = $Status
        changed = $Changed
        exitCode = $exitCode
        actionCategories = $ActionCategories
        issueCodes = $IssueCodes
        invariants = $Invariants
    }
}

function Get-ValidationScenarios {
    [CmdletBinding()]
    param()

    @(
        [pscustomobject][ordered]@{
            id = "default-call"
            invocation = ".\scripts\maintain-library.ps1"
            fixture = "Default E:\paper contains only healthy, already-maintained papers."
            expected = New-ExpectedResult -Status succeeded -Changed $false -Invariants @(
                "scope.mode is library",
                "scope.paperRoot resolves to E:\paper",
                "stdout is one parseable JSON document",
                "a no-op is still a successful maintenance run"
            )
        },
        [pscustomobject][ordered]@{
            id = "item-key-call"
            invocation = ".\scripts\maintain-library.ps1 -ItemKey PARENT1"
            fixture = "PARENT1 uniquely resolves and one exact metadata record supplies missing fields."
            expected = New-ExpectedResult -Status succeeded -Changed $true -ActionCategories @("modified") -Invariants @(
                "only the resolved paper is touched",
                "the matched record is queried once and applied as one completion action",
                "user-maintained state is preserved"
            )
        },
        [pscustomobject][ordered]@{
            id = "path-call"
            invocation = ".\scripts\maintain-library.ps1 -Path E:\paper\download.pdf"
            fixture = "The path uniquely maps by hash to one managed attachment and its canonical name is available."
            expected = New-ExpectedResult -Status succeeded -Changed $true -ActionCategories @("renamed") -Invariants @(
                "only the selected PDF and its paper are in scope",
                "the local file is renamed only after unique hash proof",
                "Zotero storage is not renamed through the filesystem"
            )
        },
        [pscustomobject][ordered]@{
            id = "duplicate-cleanup-first-run"
            invocation = ".\scripts\maintain-library.ps1 -ItemKey DUPLICATE1"
            fixture = "A strict duplicate group has one losslessly retained item and a fully verified deletion set."
            expected = New-ExpectedResult -Status succeeded -Changed $true -ActionCategories @("deleted") -Invariants @(
                "one duplicate_paper_deleted action contains every removed asset",
                "the retained item preserves transferable user state",
                "no backup, quarantine, or orphaned asset remains"
            )
        },
        [pscustomobject][ordered]@{
            id = "duplicate-cleanup-repeat"
            invocation = ".\scripts\maintain-library.ps1 -ItemKey RETAINED1"
            fixture = "The same library state is maintained again after duplicate cleanup completed."
            expected = New-ExpectedResult -Status succeeded -Changed $false -Invariants @(
                "no deletion action is repeated",
                "removed keys and paths remain absent",
                "the second run is idempotent"
            )
        },
        [pscustomobject][ordered]@{
            id = "metadata-not-found"
            invocation = ".\scripts\maintain-library.ps1 -ItemKey PARENT2"
            fixture = "The single DOI or title-plus-first-author lookup returns no exact official record."
            expected = New-ExpectedResult -Status succeeded -Changed $false -Invariants @(
                "the lookup stops after one query",
                "empty fields remain empty",
                "Extra is unchanged",
                "expected best-effort exhaustion is not reported as an unresolved error"
            )
        },
        [pscustomobject][ordered]@{
            id = "filename-conflict"
            invocation = ".\scripts\maintain-library.ps1 -Path E:\paper\download.pdf"
            fixture = "The canonical target filename already exists with a different SHA-256."
            expected = New-ExpectedResult -Status partial -Changed $false -IssueCodes @("filename_conflict") -Invariants @(
                "neither file is overwritten, merged, renamed, or deleted",
                "the issue identifies both paths and hashes",
                "the conflict is visible to embedded callers"
            )
        },
        [pscustomobject][ordered]@{
            id = "ambiguous-association"
            invocation = ".\scripts\maintain-library.ps1 -Path E:\paper\paper.pdf"
            fixture = "The local PDF can be associated with more than one Zotero attachment and no candidate is unique."
            expected = New-ExpectedResult -Status partial -Changed $false -IssueCodes @("ambiguous_association") -Invariants @(
                "no association is repaired",
                "all candidates and evidence are reported",
                "no destructive action is allowed for the ambiguous target"
            )
        },
        [pscustomobject][ordered]@{
            id = "invalid-dual-selector"
            invocation = ".\scripts\maintain-library.ps1 -ItemKey PARENT1 -Path E:\paper\paper.pdf"
            fixture = "Both mutually exclusive local selectors are supplied."
            expected = New-ExpectedResult -Status failed -Changed $false -IssueCodes @("invalid_selector") -Invariants @(
                "validation fails before inventory or mutation",
                "stdout still contains contract-valid JSON"
            )
        }
    )
}

function Get-PrototypeState {
    [CmdletBinding()]
    param(
        [string]$ScenarioId = "default-call"
    )

    $scenarios = @(Get-ValidationScenarios)
    $selected = $scenarios | Where-Object { $_.id -eq $ScenarioId } | Select-Object -First 1
    if ($null -eq $selected) {
        throw "Unknown scenario: $ScenarioId"
    }

    [pscustomobject][ordered]@{
        question = "Which legacy interfaces survive, and what validation proves the simpler maintenance skill preserves core capability?"
        policy = Get-CompatibilityPolicy
        selectedScenario = $selected
        scenarioIds = @($scenarios.id)
    }
}

Export-ModuleMember -Function Get-CompatibilityPolicy, Get-ValidationScenarios, Get-PrototypeState
