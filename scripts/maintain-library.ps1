[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true, DontShow = $true)]
    [object[]]$CommandArguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:SchemaVersion = 1
$script:ActionCategories = @("modified", "deleted", "renamed", "repaired")
$script:TargetStatuses = @("succeeded", "partial", "failed")
$script:ExitCodes = @{
    succeeded = 0
    partial = 2
    failed = 1
}

function Get-RequiredProperty {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        throw "Adapter result is missing required property '$Name'."
    }
    $property.Value
}

function New-MaintenanceIssue {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Constructs an in-memory contract object and does not change external state."
    )]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("warning", "error")]
        [string]$Severity,

        [Parameter(Mandatory = $true)]
        [string]$Code,

        [AllowNull()]
        [object]$Target,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [object[]]$Evidence = @()
    )

    [pscustomobject][ordered]@{
        severity = $Severity
        code = $Code
        target = $Target
        message = $Message
        evidence = @($Evidence)
    }
}

function New-MaintenanceScope {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Constructs an in-memory contract object and does not change external state."
    )]
    param(
        [AllowNull()]
        [string]$ItemKey,

        [AllowNull()]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$PaperRoot,

        [Parameter(Mandatory = $true)]
        [string]$ZoteroDataDir
    )

    $hasItemKey = -not [string]::IsNullOrWhiteSpace($ItemKey)
    $hasPath = -not [string]::IsNullOrWhiteSpace($Path)
    if ($hasItemKey -and $hasPath) {
        throw [System.ArgumentException]::new("ItemKey and Path are mutually exclusive.")
    }

    $mode = if ($hasItemKey) {
        "itemKey"
    }
    elseif ($hasPath) {
        "path"
    }
    else {
        "all"
    }

    [pscustomobject][ordered]@{
        mode = $mode
        selector = switch ($mode) {
            "itemKey" { $ItemKey }
            "path" { $Path }
            default { $null }
        }
        paperRoot = $PaperRoot
        zoteroDataDir = $ZoteroDataDir
    }
}

function Get-MaintenanceExitCode {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("succeeded", "partial", "failed")]
        [string]$Status
    )

    $script:ExitCodes[$Status]
}

function ConvertTo-StableMaintenanceTarget {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Target
    )

    $values = [ordered]@{}
    foreach ($name in @("parentItemKey", "attachmentKey", "path")) {
        $property = $Target.PSObject.Properties[$name]
        $values[$name] = if ($null -eq $property) { $null } else { $property.Value }
    }
    if (@($values.Values | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -eq 0) {
        throw "Adapter target must identify at least one parent item, attachment, or path."
    }

    [pscustomobject]$values
}

function ConvertTo-MaintenanceAction {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Action
    )

    $category = [string](Get-RequiredProperty -InputObject $Action -Name "category")
    if ($category -notin $script:ActionCategories) {
        throw "Adapter action category '$category' is not supported."
    }

    foreach ($name in @("kind", "target", "before", "after", "evidence")) {
        $null = Get-RequiredProperty -InputObject $Action -Name $name
    }

    [pscustomobject][ordered]@{
        category = $category
        kind = Get-RequiredProperty -InputObject $Action -Name "kind"
        target = ConvertTo-StableMaintenanceTarget -Target (Get-RequiredProperty -InputObject $Action -Name "target")
        before = Get-RequiredProperty -InputObject $Action -Name "before"
        after = Get-RequiredProperty -InputObject $Action -Name "after"
        evidence = @(Get-RequiredProperty -InputObject $Action -Name "evidence")
    }
}

function ConvertTo-MaintenanceAdapterIssue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Issue
    )

    $severity = [string](Get-RequiredProperty -InputObject $Issue -Name "severity")
    if ($severity -notin @("warning", "error")) {
        throw "Adapter issue severity '$severity' is not supported."
    }

    foreach ($name in @("code", "target", "message", "evidence")) {
        $null = Get-RequiredProperty -InputObject $Issue -Name $name
    }

    [pscustomobject][ordered]@{
        severity = $severity
        code = Get-RequiredProperty -InputObject $Issue -Name "code"
        target = ConvertTo-StableMaintenanceTarget -Target (Get-RequiredProperty -InputObject $Issue -Name "target")
        message = Get-RequiredProperty -InputObject $Issue -Name "message"
        evidence = @(Get-RequiredProperty -InputObject $Issue -Name "evidence")
    }
}

function ConvertTo-MaintenanceTargetResult {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Target,

        [Parameter(Mandatory = $true)]
        [object]$AdapterResult
    )

    $status = [string](Get-RequiredProperty -InputObject $AdapterResult -Name "status")
    if ($status -notin $script:TargetStatuses) {
        throw "Adapter target status '$status' is not supported."
    }

    $actions = @(
        foreach ($action in @(Get-RequiredProperty -InputObject $AdapterResult -Name "actions")) {
            ConvertTo-MaintenanceAction -Action $action
        }
    )
    $issues = @(
        foreach ($issue in @(Get-RequiredProperty -InputObject $AdapterResult -Name "issues")) {
            ConvertTo-MaintenanceAdapterIssue -Issue $issue
        }
    )
    if ($status -eq "succeeded" -and $issues.Count -gt 0) {
        throw "A succeeded target cannot contain unresolved issues."
    }
    if ($status -eq "partial" -and $issues.Count -eq 0) {
        throw "A partial target must contain at least one unresolved issue."
    }
    if ($status -eq "failed" -and @($issues | Where-Object { $_.severity -eq "error" }).Count -eq 0) {
        throw "A failed target must contain at least one error issue."
    }

    [pscustomobject][ordered]@{
        status = $status
        changed = $actions.Count -gt 0
        target = ConvertTo-StableMaintenanceTarget -Target $Target
        actions = $actions
        issues = $issues
    }
}

function New-MaintenanceEnvelope {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Constructs an in-memory contract object and does not change external state."
    )]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunId,

        [Parameter(Mandatory = $true)]
        [string]$StartedAt,

        [Parameter(Mandatory = $true)]
        [object]$Scope,

        [object[]]$Results = @(),

        [object[]]$Issues = @(),

        [ValidateSet("succeeded", "partial", "failed")]
        [string]$ForcedStatus
    )

    $resultsArray = @($Results)
    $runIssues = @($Issues)
    $actions = @($resultsArray | ForEach-Object { @($_.actions) })
    $targetIssues = @($resultsArray | ForEach-Object { @($_.issues) })
    $status = if ($PSBoundParameters.ContainsKey("ForcedStatus")) {
        $ForcedStatus
    }
    elseif (@($resultsArray | Where-Object { $_.status -ne "succeeded" }).Count -gt 0) {
        "partial"
    }
    else {
        "succeeded"
    }

    [pscustomobject][ordered]@{
        schemaVersion = $script:SchemaVersion
        runId = $RunId
        startedAt = $StartedAt
        completedAt = (Get-Date).ToUniversalTime().ToString("o")
        status = $status
        changed = $actions.Count -gt 0
        scope = $Scope
        summary = [pscustomobject][ordered]@{
            targetCount = $resultsArray.Count
            succeededCount = @($resultsArray | Where-Object { $_.status -eq "succeeded" }).Count
            partialCount = @($resultsArray | Where-Object { $_.status -eq "partial" }).Count
            failedCount = @($resultsArray | Where-Object { $_.status -eq "failed" }).Count
            actionCount = $actions.Count
            unresolvedCount = $runIssues.Count + $targetIssues.Count
            actionsByCategory = [pscustomobject][ordered]@{
                modified = @($actions | Where-Object { $_.category -eq "modified" }).Count
                deleted = @($actions | Where-Object { $_.category -eq "deleted" }).Count
                renamed = @($actions | Where-Object { $_.category -eq "renamed" }).Count
                repaired = @($actions | Where-Object { $_.category -eq "repaired" }).Count
            }
        }
        results = $resultsArray
        issues = $runIssues
    }
}

function ConvertFrom-MaintenanceCommandLine {
    param(
        [object[]]$Arguments
    )

    $values = [ordered]@{
        ItemKey = $null
        Path = $null
        PaperRoot = $null
        ZoteroDataDir = $null
        AdapterModulePath = $null
    }
    $names = @{
        "-itemkey" = "ItemKey"
        "-path" = "Path"
        "-paperroot" = "PaperRoot"
        "-zoterodatadir" = "ZoteroDataDir"
        "-adaptermodulepath" = "AdapterModulePath"
    }
    $seen = @{}

    for ($index = 0; $index -lt @($Arguments).Count; $index++) {
        $token = [string]$Arguments[$index]
        $lookup = $token.ToLowerInvariant()
        if (-not $names.ContainsKey($lookup)) {
            throw [System.ArgumentException]::new("Unsupported argument: $token")
        }
        $name = $names[$lookup]
        if ($seen.ContainsKey($name)) {
            throw [System.ArgumentException]::new("Argument '$token' was provided more than once.")
        }
        if ($index + 1 -ge @($Arguments).Count) {
            throw [System.ArgumentException]::new("Argument '$token' requires a value.")
        }

        $index++
        $value = [string]$Arguments[$index]
        if ($names.ContainsKey($value.ToLowerInvariant())) {
            throw [System.ArgumentException]::new("Argument '$token' requires a value.")
        }
        $values[$name] = $value
        $seen[$name] = $true
    }

    [pscustomobject]$values
}

$runId = [guid]::NewGuid().ToString()
$startedAt = (Get-Date).ToUniversalTime().ToString("o")
$scope = [pscustomobject][ordered]@{
    mode = "invalid"
    selector = $null
    paperRoot = "E:\paper"
    zoteroDataDir = "E:\ZoteroData"
}

try {
    $parsedArguments = ConvertFrom-MaintenanceCommandLine -Arguments $CommandArguments
    $resolvedPaperRoot = if ([string]::IsNullOrWhiteSpace($parsedArguments.PaperRoot)) {
        "E:\paper"
    }
    else {
        $parsedArguments.PaperRoot
    }
    $resolvedZoteroDataDir = if (-not [string]::IsNullOrWhiteSpace($parsedArguments.ZoteroDataDir)) {
        $parsedArguments.ZoteroDataDir
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:ZOTERO_DATA_DIR)) {
        $env:ZOTERO_DATA_DIR
    }
    else {
        "E:\ZoteroData"
    }

    $scope = New-MaintenanceScope `
        -ItemKey $parsedArguments.ItemKey `
        -Path $parsedArguments.Path `
        -PaperRoot $resolvedPaperRoot `
        -ZoteroDataDir $resolvedZoteroDataDir

    $workflowPath = Join-Path $PSScriptRoot "ZoteroPaperUpdater.MaintenanceWorkflow.psm1"
    Import-Module -Name $workflowPath -Force -DisableNameChecking
    $resolvedAdapterPath = if ([string]::IsNullOrWhiteSpace($parsedArguments.AdapterModulePath)) {
        Join-Path $PSScriptRoot "ZoteroPaperUpdater.MaintenanceAdapters.psm1"
    }
    else {
        $parsedArguments.AdapterModulePath
    }

    $execution = Invoke-PaperMaintenanceWorkflow `
        -Scope $scope `
        -AdapterModulePath $resolvedAdapterPath
    $resultRecords = [System.Collections.Generic.List[object]]::new()
    $fatalError = $execution.fatalError
    foreach ($record in @($execution.records)) {
        try {
            $targetResult = ConvertTo-MaintenanceTargetResult `
                -Target $record.target `
                -AdapterResult $record.adapterResult
            $resultRecords.Add($targetResult)
        }
        catch {
            $fatalError = $_
            break
        }
    }
    $results = $resultRecords.ToArray()

    if ($null -eq $fatalError) {
        $result = New-MaintenanceEnvelope `
            -RunId $runId `
            -StartedAt $startedAt `
            -Scope $scope `
            -Results $results
    }
    else {
        $fatalIssue = New-MaintenanceIssue `
            -Severity "error" `
            -Code "maintenance_run_failed" `
            -Target $null `
            -Message $fatalError.Exception.Message `
            -Evidence @(
                $fatalError.Exception.GetType().FullName,
                $fatalError.ScriptStackTrace
            )
        $result = New-MaintenanceEnvelope `
            -RunId $runId `
            -StartedAt $startedAt `
            -Scope $scope `
            -Results $results `
            -Issues @($fatalIssue) `
            -ForcedStatus "failed"
        [Console]::Error.WriteLine($fatalError.Exception.Message)
    }
}
catch {
    $issueCode = if ($_.Exception -is [System.ArgumentException] -and
        $_.Exception.Message -eq "ItemKey and Path are mutually exclusive.") {
        "selectors_mutually_exclusive"
    }
    elseif ($_.Exception -is [System.ArgumentException]) {
        "invalid_arguments"
    }
    else {
        "maintenance_run_failed"
    }
    $issue = New-MaintenanceIssue `
        -Severity "error" `
        -Code $issueCode `
        -Target $null `
        -Message $_.Exception.Message `
        -Evidence @(
            $_.Exception.GetType().FullName,
            $_.ScriptStackTrace
        )
    $result = New-MaintenanceEnvelope `
        -RunId $runId `
        -StartedAt $startedAt `
        -Scope $scope `
        -Issues @($issue) `
        -ForcedStatus "failed"
    [Console]::Error.WriteLine($_.Exception.Message)
}

$result | ConvertTo-Json -Depth 20 -Compress
$exitCode = Get-MaintenanceExitCode -Status $result.status
exit $exitCode
