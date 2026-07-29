Set-StrictMode -Version Latest

function Get-TargetPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Target,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $property = $Target.PSObject.Properties[$Name]
    if ($null -eq $property) {
        throw "Rename target is missing required property '$Name'."
    }

    $property.Value
}

function Test-PathWithinRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $rootPrefix = $fullRoot + [System.IO.Path]::DirectorySeparatorChar

    $fullPath.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-Sha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Test-ExactFilePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $parentPath = [System.IO.Path]::GetDirectoryName($fullPath)
    $expectedLeaf = [System.IO.Path]::GetFileName($fullPath)
    if (-not (Test-Path -LiteralPath $parentPath -PathType Container)) {
        return $false
    }

    @([System.IO.Directory]::GetFiles($parentPath) | Where-Object {
        [System.IO.Path]::GetFileName($_) -ceq $expectedLeaf
    }).Count -eq 1
}

function Assert-PathChainHasNoReparsePoint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $currentPath = [System.IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrWhiteSpace($currentPath)) {
        $item = $null
        try {
            $item = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
        }
        catch [System.Management.Automation.ItemNotFoundException] {
            $item = $null
        }

        if (
            $null -ne $item -and (
                ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
                -not [string]::IsNullOrWhiteSpace([string]$item.LinkType)
            )
        ) {
            $exception = [System.IO.IOException]::new(
                "Path '$([System.IO.Path]::GetFullPath($Path))' traverses reparse point '$currentPath'."
            )
            $exception.Data["ZpuIssueCode"] = "path_contains_reparse_point"
            throw $exception
        }

        $parent = [System.IO.Directory]::GetParent($currentPath)
        $currentPath = if ($null -eq $parent) { $null } else { $parent.FullName }
    }
}

function Get-PathValidationIssueCode {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $issueCode = [string]$ErrorRecord.Exception.Data["ZpuIssueCode"]
    if ($issueCode -in @("path_contains_reparse_point", "path_outside_allowed_root")) {
        return $issueCode
    }
    "path_validation_failed"
}

function New-PathValidationException {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Constructs an in-memory exception and does not change external state."
    )]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $true)]
        [ValidateSet("path_outside_allowed_root")]
        [string]$IssueCode
    )

    $exception = [System.IO.IOException]::new($Message)
    $exception.Data["ZpuIssueCode"] = $IssueCode
    $exception
}

function New-FileRenameAction {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Constructs an in-memory result and does not change external state."
    )]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Target,

        [Parameter(Mandatory = $true)]
        [object]$Plan,

        [AllowNull()]
        [string]$ActualHash
    )

    [pscustomobject][ordered]@{
        category = "renamed"
        kind = "local_pdf_renamed"
        target = $Target
        before = [pscustomobject][ordered]@{
            path = $Plan.sourcePath
            sha256 = $Plan.sourceHash
        }
        after = [pscustomobject][ordered]@{
            path = $Plan.destinationPath
            sha256 = $ActualHash
        }
        evidence = @(
            "storagePdfPath=$($Plan.storagePath)",
            "storageSha256=$($Plan.storageHash)",
            "preRenameSha256=$($Plan.sourceHash)",
            "postRenameSha256=$ActualHash"
        )
    }
}

function New-FileRenameIssueResult {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Constructs an in-memory result and does not change external state."
    )]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("partial", "failed")]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [string]$Code,

        [Parameter(Mandatory = $true)]
        [object]$Target,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [object[]]$Evidence = @(),

        [object[]]$Actions = @()
    )

    [pscustomobject][ordered]@{
        status = $Status
        actions = @($Actions)
        issues = @(
            [pscustomobject][ordered]@{
                severity = "error"
                code = $Code
                target = $Target
                message = $Message
                evidence = @($Evidence)
            }
        )
    }
}

function New-FileRenameSuccessResult {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Constructs an in-memory result and does not change external state."
    )]
    param(
        [object[]]$Actions = @()
    )

    [pscustomobject][ordered]@{
        status = "succeeded"
        actions = @($Actions)
        issues = @()
    }
}

function New-RenameStep {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Constructs an in-memory result and does not change external state."
    )]
    param(
        [AllowNull()]
        [object]$Value,

        [AllowNull()]
        [object]$Result
    )

    [pscustomobject]@{
        value = $Value
        result = $Result
    }
}

function New-FileRenameOperationTable {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Constructs bounded file-operation delegates used by the authorized caller."
    )]
    param(
        [hashtable]$Overrides = @{}
    )

    $operations = @{
        TestFile = {
            param($Path)
            Test-Path -LiteralPath $Path -PathType Leaf
        }
        TestExactFile = {
            param($Path)
            Test-ExactFilePath -Path $Path
        }
        GetSha256 = {
            param($Path)
            Get-Sha256 -Path $Path
        }
        RenameFile = {
            param($SourcePath, $DestinationPath)
            Rename-Item -LiteralPath $SourcePath -NewName (Split-Path -Leaf $DestinationPath)
        }
    }

    foreach ($operationName in $Overrides.Keys) {
        if (-not $operations.ContainsKey($operationName)) {
            throw "Unsupported file operation '$operationName'."
        }
        if ($Overrides[$operationName] -isnot [scriptblock]) {
            throw "File operation '$operationName' must be a script block."
        }
        $operations[$operationName] = $Overrides[$operationName]
    }

    $operations
}

function Resolve-ValidatedPathSet {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Paths,

        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$PathKind
    )

    @(
        foreach ($candidatePath in $Paths) {
            $fullPath = [System.IO.Path]::GetFullPath([string]$candidatePath)
            if (-not (Test-PathWithinRoot -Path $fullPath -Root $Root)) {
                throw (New-PathValidationException `
                    -Message "$PathKind path '$fullPath' is outside allowed root '$Root'." `
                    -IssueCode "path_outside_allowed_root")
            }
            Assert-PathChainHasNoReparsePoint -Path $fullPath
            $fullPath
        }
    )
}

function Resolve-RenameCandidateSet {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Target,

        [Parameter(Mandatory = $true)]
        [string]$PaperRoot,

        [Parameter(Mandatory = $true)]
        [string]$StorageRoot,

        [Parameter(Mandatory = $true)]
        [hashtable]$Operations
    )

    try {
        Assert-PathChainHasNoReparsePoint -Path $PaperRoot
        Assert-PathChainHasNoReparsePoint -Path $StorageRoot
    }
    catch {
        $result = New-FileRenameIssueResult -Status "failed" `
            -Code (Get-PathValidationIssueCode -ErrorRecord $_) -Target $Target `
            -Message $_.Exception.Message -Evidence @($PaperRoot, $StorageRoot)
        return New-RenameStep -Value $null -Result $result
    }

    $localPdfPaths = @(Get-TargetPropertyValue -Target $Target -Name "localPdfPaths")
    $storagePdfPaths = @(Get-TargetPropertyValue -Target $Target -Name "storagePdfPaths")
    if ($storagePdfPaths.Count -eq 0) {
        $result = New-FileRenameIssueResult -Status "failed" -Code "storage_pdf_missing" `
            -Target $Target -Message "No storage PDF is available to define the canonical local filename."
        return New-RenameStep -Value $null -Result $result
    }

    try {
        $storagePaths = @(Resolve-ValidatedPathSet -Paths $storagePdfPaths `
            -Root $StorageRoot -PathKind "Storage PDF")
        $localPaths = if ($localPdfPaths.Count -eq 0) {
            @()
        }
        else {
            @(Resolve-ValidatedPathSet -Paths $localPdfPaths `
                -Root $PaperRoot -PathKind "Local PDF")
        }
    }
    catch {
        $result = New-FileRenameIssueResult -Status "failed" `
            -Code (Get-PathValidationIssueCode -ErrorRecord $_) -Target $Target `
            -Message $_.Exception.Message -Evidence (@($storagePdfPaths) + $localPdfPaths)
        return New-RenameStep -Value $null -Result $result
    }

    if ($storagePaths.Count -gt 1) {
        $result = New-FileRenameIssueResult -Status "failed" -Code "storage_pdf_ambiguous" `
            -Target $Target -Message "Multiple storage PDFs could define different canonical local filenames." `
            -Evidence $storagePaths
        return New-RenameStep -Value $null -Result $result
    }

    $storagePath = $storagePaths[0]
    if (-not (& $Operations["TestFile"] $storagePath)) {
        $result = New-FileRenameIssueResult -Status "failed" -Code "storage_pdf_missing" `
            -Target $Target -Message "The storage PDF does not exist." -Evidence @($storagePath)
        return New-RenameStep -Value $null -Result $result
    }

    $existingLocalPaths = @($localPaths | Where-Object { & $Operations["TestFile"] $_ })
    if ($existingLocalPaths.Count -eq 0) {
        $message = if ($localPdfPaths.Count -eq 0) {
            "No local PDF is available for the storage attachment."
        }
        else {
            "No local PDF candidate exists."
        }
        $result = New-FileRenameIssueResult -Status "partial" -Code "local_pdf_missing" `
            -Target $Target -Message $message -Evidence (@("storagePdfPath=$storagePath") + $localPaths)
        return New-RenameStep -Value $null -Result $result
    }

    $value = [pscustomobject]@{
        storagePath = $storagePath
        localPaths = $existingLocalPaths
    }
    New-RenameStep -Value $value -Result $null
}

function Resolve-RenameHashMapping {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Target,

        [Parameter(Mandatory = $true)]
        [object]$Candidates,

        [Parameter(Mandatory = $true)]
        [hashtable]$Operations
    )

    try {
        $storageHash = & $Operations["GetSha256"] $Candidates.storagePath
        $localEvidence = @(
            foreach ($candidatePath in $Candidates.localPaths) {
                [pscustomobject][ordered]@{
                    path = $candidatePath
                    sha256 = & $Operations["GetSha256"] $candidatePath
                }
            }
        )
    }
    catch {
        $result = New-FileRenameIssueResult -Status "failed" -Code "pdf_hash_failed" `
            -Target $Target -Message $_.Exception.Message `
            -Evidence (@($Candidates.storagePath) + $Candidates.localPaths)
        return New-RenameStep -Value $null -Result $result
    }

    $matchingEvidence = @($localEvidence | Where-Object { $_.sha256 -ceq $storageHash })
    if ($matchingEvidence.Count -eq 0) {
        $storageEvidence = [pscustomobject][ordered]@{
            path = $Candidates.storagePath
            sha256 = $storageHash
        }
        $result = New-FileRenameIssueResult -Status "failed" `
            -Code "local_storage_hash_conflict" -Target $Target `
            -Message "No local PDF candidate has the storage PDF SHA-256." `
            -Evidence (@($localEvidence) + @($storageEvidence))
        return New-RenameStep -Value $null -Result $result
    }
    if ($matchingEvidence.Count -gt 1) {
        $result = New-FileRenameIssueResult -Status "failed" -Code "local_pdf_ambiguous" `
            -Target $Target -Message "Multiple local PDFs have the storage PDF SHA-256." `
            -Evidence $matchingEvidence
        return New-RenameStep -Value $null -Result $result
    }

    $value = [pscustomobject]@{
        storagePath = $Candidates.storagePath
        storageHash = $storageHash
        sourcePath = $matchingEvidence[0].path
        sourceHash = $matchingEvidence[0].sha256
    }
    New-RenameStep -Value $value -Result $null
}

function Resolve-RenameDestination {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Target,

        [Parameter(Mandatory = $true)]
        [object]$Mapping,

        [Parameter(Mandatory = $true)]
        [string]$PaperRoot,

        [Parameter(Mandatory = $true)]
        [hashtable]$Operations
    )

    $destinationPath = Join-Path `
        ([System.IO.Path]::GetDirectoryName([string]$Mapping.sourcePath)) `
        ([System.IO.Path]::GetFileName([string]$Mapping.storagePath))
    try {
        if (-not (Test-PathWithinRoot -Path $destinationPath -Root $PaperRoot)) {
            throw (New-PathValidationException `
                -Message "Rename destination '$destinationPath' is outside PaperRoot '$PaperRoot'." `
                -IssueCode "path_outside_allowed_root")
        }
        Assert-PathChainHasNoReparsePoint -Path $destinationPath
    }
    catch {
        $result = New-FileRenameIssueResult -Status "failed" `
            -Code (Get-PathValidationIssueCode -ErrorRecord $_) -Target $Target `
            -Message $_.Exception.Message `
            -Evidence @($Mapping.sourcePath, $destinationPath, $Mapping.storagePath)
        return New-RenameStep -Value $null -Result $result
    }

    $isNoOp = $Mapping.sourcePath.Equals(
        $destinationPath,
        [System.StringComparison]::Ordinal
    )
    if ($isNoOp) {
        return New-RenameStep -Value $null -Result (New-FileRenameSuccessResult)
    }

    $isCaseOnly = $Mapping.sourcePath.Equals(
        $destinationPath,
        [System.StringComparison]::OrdinalIgnoreCase
    )
    if (-not $isCaseOnly -and (& $Operations["TestFile"] $destinationPath)) {
        try {
            $destinationHash = & $Operations["GetSha256"] $destinationPath
        }
        catch {
            $result = New-FileRenameIssueResult -Status "failed" -Code "pdf_hash_failed" `
                -Target $Target -Message $_.Exception.Message -Evidence @($destinationPath)
            return New-RenameStep -Value $null -Result $result
        }
        $issueCode = if ($destinationHash -ceq $Mapping.storageHash) {
            "rename_target_duplicate"
        }
        else {
            "rename_target_conflict"
        }
        $result = New-FileRenameIssueResult -Status "failed" -Code $issueCode `
            -Target $Target -Message "The canonical local PDF path already exists; no file was overwritten." `
            -Evidence @(
                [pscustomobject][ordered]@{ path = $destinationPath; sha256 = $destinationHash },
                [pscustomobject][ordered]@{ path = $Mapping.storagePath; sha256 = $Mapping.storageHash }
            )
        return New-RenameStep -Value $null -Result $result
    }

    $plan = [pscustomobject]@{
        sourcePath = $Mapping.sourcePath
        sourceHash = $Mapping.sourceHash
        destinationPath = $destinationPath
        storagePath = $Mapping.storagePath
        storageHash = $Mapping.storageHash
        isCaseOnly = $isCaseOnly
    }
    New-RenameStep -Value $plan -Result $null
}

function Confirm-RenamePreconditionSet {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Target,

        [Parameter(Mandatory = $true)]
        [object]$Plan,

        [Parameter(Mandatory = $true)]
        [string]$PaperRoot,

        [Parameter(Mandatory = $true)]
        [string]$StorageRoot,

        [Parameter(Mandatory = $true)]
        [hashtable]$Operations
    )

    try {
        $sourceHash = & $Operations["GetSha256"] $Plan.sourcePath
        $storageHash = & $Operations["GetSha256"] $Plan.storagePath
    }
    catch {
        return New-FileRenameIssueResult -Status "failed" -Code "pdf_hash_failed" `
            -Target $Target -Message $_.Exception.Message `
            -Evidence @($Plan.sourcePath, $Plan.storagePath)
    }

    if ($sourceHash -cne $Plan.sourceHash) {
        return New-FileRenameIssueResult -Status "failed" -Code "rename_source_drift" `
            -Target $Target -Message "The local PDF changed after mapping and before rename." `
            -Evidence @(
                [pscustomobject][ordered]@{ path = $Plan.sourcePath; sha256 = $Plan.sourceHash; phase = "mapped" },
                [pscustomobject][ordered]@{ path = $Plan.sourcePath; sha256 = $sourceHash; phase = "pre_move" }
            )
    }
    if ($storageHash -cne $Plan.storageHash) {
        return New-FileRenameIssueResult -Status "failed" -Code "storage_pdf_drift" `
            -Target $Target -Message "The storage PDF changed after mapping and before rename." `
            -Evidence @(
                [pscustomobject][ordered]@{ path = $Plan.storagePath; sha256 = $Plan.storageHash; phase = "mapped" },
                [pscustomobject][ordered]@{ path = $Plan.storagePath; sha256 = $storageHash; phase = "pre_move" }
            )
    }

    try {
        foreach ($path in @(
            $PaperRoot,
            $StorageRoot,
            $Plan.sourcePath,
            $Plan.destinationPath,
            $Plan.storagePath
        )) {
            Assert-PathChainHasNoReparsePoint -Path $path
        }
    }
    catch {
        return New-FileRenameIssueResult -Status "failed" `
            -Code (Get-PathValidationIssueCode -ErrorRecord $_) -Target $Target `
            -Message $_.Exception.Message `
            -Evidence @($Plan.sourcePath, $Plan.destinationPath, $Plan.storagePath)
    }

    $null
}

function New-CaseOnlyTemporaryPath {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Selects a unique bounded path but does not create or change a file."
    )]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Plan,

        [Parameter(Mandatory = $true)]
        [string]$PaperRoot,

        [Parameter(Mandatory = $true)]
        [hashtable]$Operations
    )

    $parentPath = [System.IO.Path]::GetDirectoryName([string]$Plan.sourcePath)
    do {
        $temporaryPath = Join-Path $parentPath (
            ".zpu-rename-{0}.tmp" -f [guid]::NewGuid().ToString("N")
        )
    } while (& $Operations["TestFile"] $temporaryPath)

    if (-not (Test-PathWithinRoot -Path $temporaryPath -Root $PaperRoot)) {
        throw (New-PathValidationException `
            -Message "Case-only rename temporary path '$temporaryPath' is outside PaperRoot '$PaperRoot'." `
            -IssueCode "path_outside_allowed_root")
    }
    Assert-PathChainHasNoReparsePoint -Path $temporaryPath
    $temporaryPath
}

function Get-FileRenameState {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Plan,

        [Parameter(Mandatory = $true)]
        [hashtable]$Operations
    )

    $state = [ordered]@{
        sourceExistsKnown = $false
        sourceExists = $false
        sourceHashKnown = $false
        sourceHash = $null
        destinationExistsKnown = $false
        destinationExists = $false
        destinationHashKnown = $false
        destinationHash = $null
        errors = @()
    }

    try {
        Assert-PathChainHasNoReparsePoint -Path $Plan.sourcePath
        $state.sourceExists = & $Operations["TestExactFile"] $Plan.sourcePath
        $state.sourceExistsKnown = $true
    }
    catch {
        $state.errors += "sourceExists=$($_.Exception.Message)"
    }
    try {
        Assert-PathChainHasNoReparsePoint -Path $Plan.destinationPath
        $state.destinationExists = & $Operations["TestExactFile"] $Plan.destinationPath
        $state.destinationExistsKnown = $true
    }
    catch {
        $state.errors += "destinationExists=$($_.Exception.Message)"
    }
    if ($state.sourceExistsKnown -and $state.sourceExists) {
        try {
            $state.sourceHash = & $Operations["GetSha256"] $Plan.sourcePath
            $state.sourceHashKnown = $true
        }
        catch {
            $state.errors += "sourceHash=$($_.Exception.Message)"
        }
    }
    if ($state.destinationExistsKnown -and $state.destinationExists) {
        try {
            $state.destinationHash = & $Operations["GetSha256"] $Plan.destinationPath
            $state.destinationHashKnown = $true
        }
        catch {
            $state.errors += "destinationHash=$($_.Exception.Message)"
        }
    }

    [pscustomobject]$state
}

function Test-RenamePostcondition {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Plan,

        [Parameter(Mandatory = $true)]
        [object]$State
    )

    $State.sourceExistsKnown -and
        -not $State.sourceExists -and
        $State.destinationExistsKnown -and
        $State.destinationExists -and
        $State.destinationHashKnown -and
        $State.destinationHash -ceq $Plan.sourceHash
}

function Test-RenameRollbackVerified {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Plan,

        [Parameter(Mandatory = $true)]
        [object]$State
    )

    $State.sourceExistsKnown -and
        $State.sourceExists -and
        $State.sourceHashKnown -and
        $State.sourceHash -ceq $Plan.sourceHash -and
        $State.destinationExistsKnown -and
        -not $State.destinationExists
}

function Invoke-StandardRenameRollback {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Rolls back only the bounded rename already authorized by the caller."
    )]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Plan,

        [Parameter(Mandatory = $true)]
        [object]$PostMoveState,

        [Parameter(Mandatory = $true)]
        [hashtable]$Operations
    )

    $errorMessage = $null
    if (
        $PostMoveState.sourceExistsKnown -and
        -not $PostMoveState.sourceExists -and
        $PostMoveState.destinationExistsKnown -and
        $PostMoveState.destinationExists
    ) {
        try {
            Assert-PathChainHasNoReparsePoint -Path $Plan.sourcePath
            Assert-PathChainHasNoReparsePoint -Path $Plan.destinationPath
            & $Operations["RenameFile"] $Plan.destinationPath $Plan.sourcePath
        }
        catch {
            $errorMessage = $_.Exception.Message
        }
    }
    else {
        $errorMessage = "Rollback was unsafe because a completed rename was not proven."
    }

    [pscustomobject]@{
        state = Get-FileRenameState -Plan $Plan -Operations $Operations
        error = $errorMessage
    }
}

function Invoke-CaseOnlyRenameRollback {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Rolls back only the bounded case-only rename already authorized by the caller."
    )]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Plan,

        [AllowNull()]
        [string]$TemporaryPath,

        [Parameter(Mandatory = $true)]
        [string]$PaperRoot,

        [Parameter(Mandatory = $true)]
        [hashtable]$Operations
    )

    $errorMessage = $null
    try {
        $sourceExists = & $Operations["TestExactFile"] $Plan.sourcePath
        $destinationExists = & $Operations["TestExactFile"] $Plan.destinationPath
        $temporaryExists = if ($null -eq $TemporaryPath) {
            $false
        }
        else {
            & $Operations["TestExactFile"] $TemporaryPath
        }
        if ($temporaryExists -and -not $sourceExists -and -not $destinationExists) {
            Assert-PathChainHasNoReparsePoint -Path $TemporaryPath
            & $Operations["RenameFile"] $TemporaryPath $Plan.sourcePath
        }
        elseif ($destinationExists -and -not $sourceExists -and -not $temporaryExists) {
            $rollbackTemporary = New-CaseOnlyTemporaryPath -Plan $Plan `
                -PaperRoot $PaperRoot -Operations $Operations
            & $Operations["RenameFile"] $Plan.destinationPath $rollbackTemporary
            & $Operations["RenameFile"] $rollbackTemporary $Plan.sourcePath
        }
        elseif (-not ($sourceExists -and -not $destinationExists -and -not $temporaryExists)) {
            $errorMessage = "Case-only rollback was unsafe because the file location was ambiguous."
        }
    }
    catch {
        $errorMessage = $_.Exception.Message
    }

    [pscustomobject]@{
        state = Get-FileRenameState -Plan $Plan -Operations $Operations
        error = $errorMessage
    }
}

function Resolve-RenameFailureResult {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Target,

        [Parameter(Mandatory = $true)]
        [object]$Plan,

        [Parameter(Mandatory = $true)]
        [object]$PostMoveState,

        [Parameter(Mandatory = $true)]
        [object]$Rollback,

        [Parameter(Mandatory = $true)]
        [string]$IssueCode,

        [Parameter(Mandatory = $true)]
        [string]$FailureMessage
    )

    $actions = @()
    if (Test-RenameRollbackVerified -Plan $Plan -State $Rollback.state) {
        $message = "$FailureMessage The original source path and SHA-256 were restored."
    }
    else {
        $message = "$FailureMessage Rollback could not be verified from the final filesystem state."
        $finalState = $Rollback.state
        $persistedRenameProven = (
            $finalState.sourceExistsKnown -and
            -not $finalState.sourceExists -and
            $finalState.destinationExistsKnown -and
            $finalState.destinationExists -and
            $finalState.destinationHashKnown -and
            $finalState.destinationHash -ceq $Plan.sourceHash
        )
        if ($persistedRenameProven) {
            $actions = @(
                New-FileRenameAction -Target $Target -Plan $Plan `
                    -ActualHash $finalState.destinationHash
            )
        }
    }

    New-FileRenameIssueResult -Status "failed" -Code $IssueCode -Target $Target `
        -Message $message -Evidence @(
            [pscustomobject]@{ phase = "post_move"; state = $PostMoveState },
            [pscustomobject]@{ phase = "rollback"; state = $Rollback.state; error = $Rollback.error }
        ) -Actions $actions
}

function Invoke-RenameTransaction {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "The caller has already authorized this bounded local rename operation."
    )]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Target,

        [Parameter(Mandatory = $true)]
        [object]$Plan,

        [Parameter(Mandatory = $true)]
        [string]$PaperRoot,

        [Parameter(Mandatory = $true)]
        [hashtable]$Operations
    )

    $moveError = $null
    $temporaryPath = $null
    try {
        if ($Plan.isCaseOnly) {
            $temporaryPath = New-CaseOnlyTemporaryPath -Plan $Plan `
                -PaperRoot $PaperRoot -Operations $Operations
            & $Operations["RenameFile"] $Plan.sourcePath $temporaryPath
            & $Operations["RenameFile"] $temporaryPath $Plan.destinationPath
        }
        else {
            & $Operations["RenameFile"] $Plan.sourcePath $Plan.destinationPath
        }
    }
    catch {
        $moveError = $_.Exception.Message
    }

    $postMoveState = Get-FileRenameState -Plan $Plan -Operations $Operations
    if ($null -eq $moveError -and (Test-RenamePostcondition -Plan $Plan -State $postMoveState)) {
        $action = New-FileRenameAction -Target $Target -Plan $Plan `
            -ActualHash $postMoveState.destinationHash
        return New-FileRenameSuccessResult -Actions @($action)
    }

    $rollback = if ($Plan.isCaseOnly) {
        Invoke-CaseOnlyRenameRollback -Plan $Plan -TemporaryPath $temporaryPath `
            -PaperRoot $PaperRoot -Operations $Operations
    }
    else {
        Invoke-StandardRenameRollback -Plan $Plan -PostMoveState $postMoveState `
            -Operations $Operations
    }
    $issueCode = if ($null -eq $moveError) {
        "rename_postcondition_failed"
    }
    else {
        "rename_move_failed"
    }
    $message = if ($null -eq $moveError) {
        "The local PDF rename failed its path or SHA-256 postcondition."
    }
    else {
        "The local PDF move reported an error: $moveError"
    }
    Resolve-RenameFailureResult -Target $Target -Plan $Plan `
        -PostMoveState $postMoveState -Rollback $rollback `
        -IssueCode $issueCode -FailureMessage $message
}

function Invoke-LocalPdfRename {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "The caller has already authorized this bounded local rename operation."
    )]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Target,

        [Parameter(Mandatory = $true)]
        [string]$PaperRoot,

        [Parameter(Mandatory = $true)]
        [string]$StorageRoot,

        [hashtable]$FileOperations = @{}
    )

    $operations = New-FileRenameOperationTable -Overrides $FileOperations
    $candidateStep = Resolve-RenameCandidateSet -Target $Target `
        -PaperRoot $PaperRoot -StorageRoot $StorageRoot -Operations $operations
    if ($null -ne $candidateStep.result) {
        return $candidateStep.result
    }

    $mappingStep = Resolve-RenameHashMapping -Target $Target `
        -Candidates $candidateStep.value -Operations $operations
    if ($null -ne $mappingStep.result) {
        return $mappingStep.result
    }

    $destinationStep = Resolve-RenameDestination -Target $Target `
        -Mapping $mappingStep.value -PaperRoot $PaperRoot -Operations $operations
    if ($null -ne $destinationStep.result) {
        return $destinationStep.result
    }

    $preconditionFailure = Confirm-RenamePreconditionSet -Target $Target `
        -Plan $destinationStep.value -PaperRoot $PaperRoot `
        -StorageRoot $StorageRoot -Operations $operations
    if ($null -ne $preconditionFailure) {
        return $preconditionFailure
    }

    Invoke-RenameTransaction -Target $Target -Plan $destinationStep.value `
        -PaperRoot $PaperRoot -Operations $operations
}

Export-ModuleMember -Function Invoke-LocalPdfRename
