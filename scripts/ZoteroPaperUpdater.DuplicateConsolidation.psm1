Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "ZoteroPaperUpdater.Common.psm1") -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "ZoteroPaperUpdater.DuplicateIdentity.psm1") -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "ZoteroPaperUpdater.DuplicateCleanup.psm1") -DisableNameChecking

function Get-ConsolidationStringSet {
    param([AllowNull()][object[]]$Value)

    @(
        @($Value) |
            ForEach-Object {
                if ($null -eq $_) { return }
                $tag = Get-OptionalPropertyValue -Object $_ -Name "tag"
                if ($null -ne $tag) { [string]$tag } else { [string]$_ }
            } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
}

function Merge-ConsolidationTag {
    param([Parameter(Mandatory = $true)][object[]]$Members)

    $byIdentity = [ordered]@{}
    foreach ($tagValue in @(
        $Members | ForEach-Object {
            @(Get-OptionalPropertyValue -Object $_.parent -Name "tags")
        }
    )) {
        if ($null -eq $tagValue) { continue }
        $tag = Get-OptionalPropertyValue -Object $tagValue -Name "tag"
        if ($null -eq $tag) { $tag = [string]$tagValue }
        if ([string]::IsNullOrWhiteSpace([string]$tag)) { continue }
        $typeValue = Get-OptionalPropertyValue -Object $tagValue -Name "type"
        $type = if ($null -eq $typeValue) { 0 } else { [int]$typeValue }
        $identity = "$([string]$tag)`u{001f}$type"
        $byIdentity[$identity] = [pscustomobject][ordered]@{
            tag = [string]$tag
            type = $type
        }
    }
    @($byIdentity.GetEnumerator() | Sort-Object Name | ForEach-Object { $_.Value })
}

function Test-ConsolidationTagTypeConflict {
    param([Parameter(Mandatory = $true)][object[]]$Members)

    $typesByTag = @{}
    foreach ($tagValue in @($Members | ForEach-Object { @($_.parent.tags) })) {
        $tag = Get-OptionalPropertyValue -Object $tagValue -Name "tag"
        if ($null -eq $tag) { $tag = [string]$tagValue }
        $typeValue = Get-OptionalPropertyValue -Object $tagValue -Name "type"
        $type = if ($null -eq $typeValue) { 0 } else { [int]$typeValue }
        if (-not $typesByTag.ContainsKey([string]$tag)) {
            $typesByTag[[string]$tag] = $type
        }
        elseif ([int]$typesByTag[[string]$tag] -ne $type) {
            return $true
        }
    }
    $false
}

function Get-ConsolidationRelationEntry {
    param([AllowNull()][object]$Relations)

    if ($null -eq $Relations) { return @() }
    @(
        foreach ($property in $Relations.PSObject.Properties | Sort-Object Name) {
            foreach ($value in @(Get-ConsolidationStringSet -Value @($property.Value))) {
                [pscustomobject][ordered]@{
                    predicate = [string]$property.Name
                    value = $value
                }
            }
        }
    )
}

function Merge-ConsolidationRelation {
    param([Parameter(Mandatory = $true)][object[]]$Members)

    $merged = [ordered]@{}
    foreach ($entry in @(
        $Members |
            ForEach-Object {
                Get-ConsolidationRelationEntry `
                    -Relations (Get-OptionalPropertyValue -Object $_.parent -Name "relations")
            } |
            Sort-Object predicate, value -Unique
    )) {
        if (-not $merged.Contains($entry.predicate)) {
            $merged[$entry.predicate] = [Collections.Generic.List[string]]::new()
        }
        $merged[$entry.predicate].Add($entry.value)
    }
    $result = [ordered]@{}
    foreach ($predicate in $merged.Keys) {
        $result[$predicate] = @($merged[$predicate])
    }
    [pscustomobject]$result
}

function Get-ConsolidationParentScore {
    param([Parameter(Mandatory = $true)][object]$Member)

    $parent = $Member.parent
    @(
        Get-ConsolidationStringSet -Value @(
            Get-OptionalPropertyValue -Object $parent -Name "tags"
        )
    ).Count +
    @(
        Get-ConsolidationStringSet -Value @(
            Get-OptionalPropertyValue -Object $parent -Name "collections"
        )
    ).Count +
    @(
        Get-ConsolidationRelationEntry `
            -Relations (Get-OptionalPropertyValue -Object $parent -Name "relations")
    ).Count +
    @(
        Get-ConsolidationStringSet -Value @(
            Get-OptionalPropertyValue -Object $parent -Name "notes"
        )
    ).Count +
    @(
        Get-OptionalPropertyValue -Object $parent -Name "inboundRelations"
    ).Count
}

function Get-ConsolidationCacheCompleteness {
    param([Parameter(Mandatory = $true)][object]$Cache)

    $score = 0
    if ([bool](Get-OptionalPropertyValue -Object $Cache -Name "healthy")) { $score += 2 }
    if ([bool](Get-OptionalPropertyValue -Object $Cache -Name "complete")) { $score += 1 }
    $score
}

function Get-ConsolidationParsedAt {
    param([Parameter(Mandatory = $true)][object]$Cache)

    $value = [string](Get-OptionalPropertyValue -Object $Cache -Name "parsedAt")
    $parsed = [datetime]::MinValue
    if (-not [string]::IsNullOrWhiteSpace($value)) {
        $null = [datetime]::TryParse(
            $value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal,
            [ref]$parsed
        )
    }
    $parsed
}

function Get-ConsolidationRetainedParentMember {
    param([Parameter(Mandatory = $true)][object[]]$Members)

    @(
        $Members |
            Sort-Object `
                @{ Expression = { Get-ConsolidationParentScore -Member $_ }; Descending = $true }, `
                @{ Expression = { [string]$_.parent.dateAdded } }, `
                @{ Expression = { [string]$_.parent.key } }
    )[0]
}

function Get-ConsolidationRetainedAttachmentMember {
    param([Parameter(Mandatory = $true)][object[]]$Members)

    @(
        $Members |
            Sort-Object `
                @{ Expression = {
                    [int][bool](Get-OptionalPropertyValue -Object $_.attachment -Name "hasAnnotations")
                }; Descending = $true }, `
                @{ Expression = {
                    [int][bool](Get-OptionalPropertyValue -Object $_.attachment -Name "isFinal")
                }; Descending = $true }, `
                @{ Expression = { Get-ConsolidationCacheCompleteness -Cache $_.cache }; Descending = $true }, `
                @{ Expression = { Get-ConsolidationParsedAt -Cache $_.cache }; Descending = $true }, `
                @{ Expression = { [string]$_.attachment.key } }
    )[0]
}

function New-ConsolidationBlockedDecision {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Constructs an in-memory decision and does not change external state."
    )]
    param([Parameter(Mandatory = $true)][string]$Code, [Parameter(Mandatory = $true)][string]$Message)

    [pscustomobject][ordered]@{
        status = "blocked"
        issue = [pscustomobject][ordered]@{
            code = $Code
            message = $Message
        }
    }
}

function Get-ConsolidationLosslessStateIssue {
    param(
        [Parameter(Mandatory = $true)][object[]]$Members,
        [Parameter(Mandatory = $true)][object]$RetainedMember,
        [Parameter(Mandatory = $true)][object]$RetainedAttachmentMember
    )

    if (@($Members | Where-Object {
        [bool](Get-OptionalPropertyValue -Object $_.attachment -Name "hasAnnotations")
    }).Count -gt 1) {
        return New-ConsolidationBlockedDecision `
            -Code "duplicate_annotations_not_lossless" `
            -Message "Annotations are spread across attachments and cannot be consolidated losslessly."
    }
    $retainedNotes = @(Get-ConsolidationStringSet -Value @(
        Get-OptionalPropertyValue -Object $RetainedMember.parent -Name "notes"
    ))
    foreach ($member in @($Members | Where-Object {
        [string]$_.parent.key -cne [string]$RetainedMember.parent.key
    })) {
        if (@(
            Get-ConsolidationStringSet -Value @(
                Get-OptionalPropertyValue -Object $member.parent -Name "notes"
            ) |
                Where-Object { $_ -cnotin $retainedNotes }
        ).Count -gt 0) {
            return New-ConsolidationBlockedDecision `
                -Code "duplicate_notes_not_lossless" `
                -Message "A losing parent contains distinct notes that cannot be represented losslessly."
        }
        if (@(Get-OptionalPropertyValue -Object $member.parent -Name "unknownChildren").Count -gt 0) {
            return New-ConsolidationBlockedDecision `
                -Code "duplicate_child_state_unknown" `
                -Message "A losing parent contains unknown child state."
        }
    }
    foreach ($member in @($Members | Where-Object {
        [string]$_.attachment.key -cne [string]$RetainedAttachmentMember.attachment.key
    })) {
        if (@(Get-ConsolidationStringSet -Value @(
                Get-OptionalPropertyValue -Object $member.attachment -Name "tags"
            )).Count -gt 0 -or
            @(Get-ConsolidationRelationEntry -Relations (
                Get-OptionalPropertyValue -Object $member.attachment -Name "relations"
            )).Count -gt 0) {
            return New-ConsolidationBlockedDecision `
                -Code "duplicate_attachment_state_not_lossless" `
                -Message "A redundant attachment contains state that cannot be migrated losslessly."
        }
    }
    if (Test-ConsolidationTagTypeConflict -Members $Members) {
        return New-ConsolidationBlockedDecision `
            -Code "duplicate_tag_type_conflict" `
            -Message "The same Zotero tag has conflicting assignment types across duplicate parents."
    }
    $null
}

function New-ConsolidationMergedState {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Constructs an immutable merged-state value."
    )]
    param([Parameter(Mandatory = $true)][object[]]$Members)

    [pscustomobject][ordered]@{
        tags = @(Merge-ConsolidationTag -Members $Members)
        collections = @(
            Get-ConsolidationStringSet -Value @(
                $Members | ForEach-Object { @($_.parent.collections) }
            )
        )
        relations = Merge-ConsolidationRelation -Members $Members
    }
}

function New-ConsolidationWriteRequest {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Constructs immutable optimistic write requests."
    )]
    param(
        [Parameter(Mandatory = $true)][object]$RetainedMember,
        [Parameter(Mandatory = $true)][object]$RetainedAttachmentMember,
        [Parameter(Mandatory = $true)][object]$MergedState
    )

    $parentKey = [string]$RetainedMember.parent.key
    [pscustomobject][ordered]@{
        parent = [pscustomobject][ordered]@{
            parentItemKey = $parentKey
            expectedVersion = $RetainedMember.parent.version
            tags = $MergedState.tags
            collections = $MergedState.collections
            relations = $MergedState.relations
        }
        attachment = if ([string]$RetainedAttachmentMember.parent.key -cne $parentKey) {
            [pscustomobject][ordered]@{
                attachmentKey = [string]$RetainedAttachmentMember.attachment.key
                expectedVersion = $RetainedAttachmentMember.attachment.version
                parentItemKey = $parentKey
            }
        }
        else { $null }
    }
}

function Get-DuplicateConsolidationDecision {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$GroupSnapshot)

    $members = @(Get-RequiredPropertyValue -Object $GroupSnapshot -Name "members")
    if ($members.Count -lt 2) {
        throw "A duplicate consolidation group must contain at least two existing items."
    }
    $identity = Get-DuplicateIdentityEvidence -Members $members
    if ([string]$identity.status -eq "blocked") {
        return New-ConsolidationBlockedDecision -Code $identity.code -Message $identity.message
    }

    $retainedMember = Get-ConsolidationRetainedParentMember -Members $members
    $retainedParentKey = [string]$retainedMember.parent.key
    $losingMembers = @($members | Where-Object { [string]$_.parent.key -cne $retainedParentKey })
    $retainedAttachmentMember = Get-ConsolidationRetainedAttachmentMember -Members $members
    $retainedAttachment = $retainedAttachmentMember.attachment
    $losslessIssue = Get-ConsolidationLosslessStateIssue `
        -Members $members `
        -RetainedMember $retainedMember `
        -RetainedAttachmentMember $retainedAttachmentMember
    if ($null -ne $losslessIssue) { return $losslessIssue }
    $mergedState = New-ConsolidationMergedState -Members $members
    $mergedTags = $mergedState.tags
    $mergedCollections = $mergedState.collections
    $mergedRelations = $mergedState.relations
    $inboundRewrites = @(
        foreach ($member in $losingMembers) {
            foreach ($relation in @(
                Get-OptionalPropertyValue -Object $member.parent -Name "inboundRelations"
            )) {
                if ($null -eq (Get-OptionalPropertyValue -Object $relation -Name "sourceKey") -or
                    $null -eq (Get-OptionalPropertyValue -Object $relation -Name "predicate")) {
                    return New-ConsolidationBlockedDecision `
                        -Code "duplicate_relation_not_representable" `
                        -Message "An inbound relation cannot be represented for lossless rewrite."
                }
                $oldTargetValue = if (
                    $null -ne (Get-OptionalPropertyValue -Object $relation -Name "oldTargetValue")
                ) {
                    [string]$relation.oldTargetValue
                }
                else { [string]$member.parent.key }
                $newTargetValue = if (
                    $null -ne (Get-OptionalPropertyValue -Object $relation -Name "oldTargetValue")
                ) {
                    $oldTargetValue -replace
                        ([regex]::Escape([string]$member.parent.key) + "$"),
                        $retainedParentKey
                }
                else { $retainedParentKey }
                if ([string]$relation.sourceKey -ceq $retainedParentKey) {
                    $rewrittenValues = @(
                        Get-OptionalPropertyValue `
                            -Object $mergedRelations `
                            -Name ([string]$relation.predicate) |
                            ForEach-Object {
                                if ([string]$_ -ceq $oldTargetValue) {
                                    $newTargetValue
                                }
                                else { [string]$_ }
                            } |
                            Sort-Object -Unique
                    )
                    $property = $mergedRelations.PSObject.Properties[
                        [string]$relation.predicate
                    ]
                    if ($null -eq $property) {
                        $mergedRelations | Add-Member `
                            -NotePropertyName ([string]$relation.predicate) `
                            -NotePropertyValue $rewrittenValues
                    }
                    else {
                        $property.Value = $rewrittenValues
                    }
                    continue
                }
                [pscustomobject][ordered]@{
                    sourceKey = [string]$relation.sourceKey
                    expectedVersion = Get-RequiredPropertyValue -Object $relation -Name "sourceVersion"
                    predicate = [string]$relation.predicate
                    oldTargetKey = $oldTargetValue
                    newTargetKey = $newTargetValue
                }
            }
        }
    )
    $writeRequests = New-ConsolidationWriteRequest `
        -RetainedMember $retainedMember `
        -RetainedAttachmentMember $retainedAttachmentMember `
        -MergedState $mergedState
    $parentWriteRequest = $writeRequests.parent
    $attachmentWriteRequest = $writeRequests.attachment
    $currentTags = @(Merge-ConsolidationTag -Members @($retainedMember))
    $currentCollections = @(
        Get-ConsolidationStringSet -Value @($retainedMember.parent.collections)
    )
    $requiresWrite = -not (
        (Test-DeepValueEqual -Left $currentTags -Right $mergedTags) -and
        (Test-DeepValueEqual -Left $currentCollections -Right $mergedCollections) -and
        (Test-DeepValueEqual -Left $retainedMember.parent.relations -Right $mergedRelations) -and
        $null -eq $attachmentWriteRequest -and
        $inboundRewrites.Count -eq 0
    )

    [pscustomobject][ordered]@{
        status = "eligible"
        identity = $identity
        members = $members
        retainedParent = $retainedMember.parent
        retainedAttachment = $retainedAttachment
        mergedState = [pscustomobject][ordered]@{
            tags = $mergedTags
            collections = $mergedCollections
            relations = $mergedRelations
        }
        parentWriteRequest = $parentWriteRequest
        attachmentWriteRequest = $attachmentWriteRequest
        inboundRelationWrites = $inboundRewrites
        losingParentKeys = @($losingMembers.parent.key)
        requiresWrite = $requiresWrite
        expectedAfter = [pscustomobject][ordered]@{
            retainedParentKey = $retainedParentKey
            retainedAttachmentKey = [string]$retainedAttachment.key
            attachmentParentItemKey = $retainedParentKey
            mergedState = [pscustomobject][ordered]@{
                tags = $mergedTags
                collections = $mergedCollections
                relations = $mergedRelations
            }
        }
    }
}

function ConvertTo-ConsolidationCleanupCandidate {
    param([Parameter(Mandatory = $true)][object]$Decision)

    if ([string]$Decision.status -cne "eligible") {
        throw "Only an eligible consolidation decision can become a cleanup candidate."
    }
    $members = @($Decision.members)
    $retainedParentMember = @(
        $members | Where-Object {
            [string]$_.parent.key -ceq [string]$Decision.retainedParent.key
        }
    )[0]
    $retainedAttachmentMember = @(
        $members | Where-Object {
            [string]$_.attachment.key -ceq [string]$Decision.retainedAttachment.key
        }
    )[0]
    $losingParentMembers = @(
        $members |
            Where-Object {
                [string]$_.parent.key -cne [string]$Decision.retainedParent.key
            } |
            Sort-Object { [string]$_.parent.key }
    )
    $redundantAttachmentMembers = @(
        $members |
            Where-Object {
                [string]$_.attachment.key -cne [string]$Decision.retainedAttachment.key
            } |
            Sort-Object { [string]$_.attachment.key }
    )
    if ($losingParentMembers.Count -ne $redundantAttachmentMembers.Count) {
        throw "Existing duplicate components cannot be paired into one retained set."
    }
    $retain = [pscustomobject][ordered]@{
        parent = $retainedParentMember.parent
        attachment = $retainedAttachmentMember.attachment
        storage = $retainedAttachmentMember.storage
        cache = [Management.Automation.PSSerializer]::Deserialize(
            [Management.Automation.PSSerializer]::Serialize(
                $retainedAttachmentMember.cache,
                20
            )
        )
        local = $retainedAttachmentMember.local
        userStateEmpty = $false
    }
    if ($retain.cache.PSObject.Properties["parentItemKey"]) {
        $retain.cache.parentItemKey = [string]$Decision.retainedParent.key
    }
    $removals = @(
        for ($index = 0; $index -lt $losingParentMembers.Count; $index++) {
            [pscustomobject][ordered]@{
                parent = $losingParentMembers[$index].parent
                attachment = $redundantAttachmentMembers[$index].attachment
                storage = $redundantAttachmentMembers[$index].storage
                cache = $redundantAttachmentMembers[$index].cache
                local = $redundantAttachmentMembers[$index].local
                userStateEmpty = $true
            }
        }
    )
    [pscustomobject][ordered]@{
        retain = $retain
        remove = $removals[0]
        removals = $removals
        consolidationDecision = $Decision
    }
}

function Invoke-DuplicateConsolidationCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Scope,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$GroupSnapshots,
        [Parameter(Mandatory = $true)][object]$Operations
    )

    $decisions = @(
        foreach ($snapshot in $GroupSnapshots) {
            Get-DuplicateConsolidationDecision -GroupSnapshot $snapshot
        }
    )
    $results = [Collections.Generic.List[object]]::new()
    foreach ($decision in $decisions) {
        if ([string]$decision.status -eq "blocked") {
            $results.Add([pscustomobject][ordered]@{
                target = [pscustomobject]@{
                    parentItemKey = $null
                    attachmentKey = $null
                    path = $null
                }
                status = "failed"
                actions = @()
                issues = @([pscustomobject][ordered]@{
                    severity = "error"
                    code = [string]$decision.issue.code
                    target = $null
                    message = [string]$decision.issue.message
                    evidence = @()
                })
            })
            continue
        }
        $candidate = ConvertTo-ConsolidationCleanupCandidate -Decision $decision
        $results.Add((Invoke-CleanupCandidateTransaction `
            -Scope $Scope `
            -Candidate $candidate `
            -Operations $Operations))
    }
    $failed = @($results | Where-Object { $_.status -eq "failed" }).Count
    $succeeded = $results.Count - $failed
    [pscustomobject][ordered]@{
        status = if ($failed -eq 0) { "succeeded" } elseif ($succeeded -eq 0) { "failed" } else { "partial" }
        results = @($results)
        actions = @($results | ForEach-Object { @($_.actions) })
        issues = @($results | ForEach-Object { @($_.issues) })
    }
}

Export-ModuleMember -Function `
    Get-DuplicateConsolidationDecision, `
    Invoke-DuplicateConsolidationCleanup
