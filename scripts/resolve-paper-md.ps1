[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$ItemKey,

    [string]$ZoteroDataDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "ZoteroPaperUpdater.Common.psm1") -Force

$resolvedZoteroDataDir = Resolve-ZoteroDataDirectory -RequestedPath $ZoteroDataDir
$mineruRoot = Join-Path $resolvedZoteroDataDir "llm-for-zotero-mineru"
$storageRoot = Join-Path $resolvedZoteroDataDir "storage"

if (-not (Test-Path -LiteralPath $mineruRoot -PathType Container)) {
    throw "MinerU cache root not found: $mineruRoot"
}
if (-not (Test-Path -LiteralPath $storageRoot -PathType Container)) {
    throw "Zotero storage root not found: $storageRoot"
}

$normalizedKey = $ItemKey.Trim()
$matches = [System.Collections.Generic.List[object]]::new()
$invalidProvenance = [System.Collections.Generic.List[object]]::new()
$sourceFiles = @(Get-ChildItem -LiteralPath $mineruRoot -Recurse -File -Filter "_llm_source.json")

foreach ($sourceFile in $sourceFiles) {
    try {
        $source = Get-Content -LiteralPath $sourceFile.FullName -Raw | ConvertFrom-Json
    }
    catch {
        $invalidProvenance.Add((New-Issue -Severity "warning" -Code "invalid_provenance_json" -Message "$($sourceFile.FullName): $($_.Exception.Message)"))
        continue
    }

    $attachmentId = [string](Get-OptionalPropertyValue -Object $source -Name "attachmentId")
    $attachmentKey = [string](Get-OptionalPropertyValue -Object $source -Name "attachmentKey")
    $parentItemKey = [string](Get-OptionalPropertyValue -Object $source -Name "parentItemKey")
    $directoryName = $sourceFile.Directory.Name

    $matchKind = $null
    if ($normalizedKey.Equals($attachmentKey, [System.StringComparison]::OrdinalIgnoreCase)) {
        $matchKind = "attachmentKey"
    }
    elseif ($normalizedKey.Equals($parentItemKey, [System.StringComparison]::OrdinalIgnoreCase)) {
        $matchKind = "parentItemKey"
    }
    elseif ($normalizedKey -eq $attachmentId -or $normalizedKey -eq $directoryName) {
        $matchKind = "attachmentId"
    }

    if ($null -ne $matchKind) {
        $matches.Add([pscustomobject]@{
            matchKind = $matchKind
            sourceFile = $sourceFile.FullName
            cacheDirectory = $sourceFile.Directory.FullName
            source = $source
        })
    }
}

if ($matches.Count -ne 1) {
    $result = [pscustomobject]@{
        status = "error"
        requestedKey = $normalizedKey
        zoteroDataDir = $resolvedZoteroDataDir
        mineruRoot = $mineruRoot
        matchCount = $matches.Count
        matches = @($matches | ForEach-Object {
            [pscustomobject]@{
                matchKind = $_.matchKind
                cacheDirectory = $_.cacheDirectory
                attachmentId = Get-OptionalPropertyValue -Object $_.source -Name "attachmentId"
                attachmentKey = Get-OptionalPropertyValue -Object $_.source -Name "attachmentKey"
                parentItemKey = Get-OptionalPropertyValue -Object $_.source -Name "parentItemKey"
            }
        })
        invalidProvenanceWarnings = $invalidProvenance
        message = if ($matches.Count -eq 0) {
            "No MinerU cache provenance matches the requested Zotero key or attachment ID."
        }
        else {
            "The requested parent resolves to multiple MinerU caches; select a specific attachmentKey."
        }
    }
    $result | ConvertTo-Json -Depth 8
    exit 2
}

$match = $matches[0]
$source = $match.source
$cacheDirectory = $match.cacheDirectory
$issues = [System.Collections.Generic.List[object]]::new()

$kind = [string](Get-OptionalPropertyValue -Object $source -Name "kind")
$versionValue = Get-OptionalPropertyValue -Object $source -Name "version"
$attachmentIdValue = Get-OptionalPropertyValue -Object $source -Name "attachmentId"
$attachmentId = if ($null -ne $attachmentIdValue) { [long]$attachmentIdValue } else { 0 }
$attachmentKey = [string](Get-OptionalPropertyValue -Object $source -Name "attachmentKey")
$parentItemKey = [string](Get-OptionalPropertyValue -Object $source -Name "parentItemKey")
$sourceFilename = [string](Get-OptionalPropertyValue -Object $source -Name "sourceFilename")

if ($kind -ne "llm-for-zotero/mineru-cache-source") {
    $issues.Add((New-Issue -Severity "error" -Code "provenance_kind_invalid" -Message "Unexpected provenance kind '$kind' in $($match.sourceFile)"))
}
if ($null -eq $versionValue -or [long]$versionValue -ne 2) {
    $issues.Add((New-Issue -Severity "error" -Code "provenance_version_invalid" -Message "Expected provenance version 2 in $($match.sourceFile)"))
}
if ($attachmentId -le 0) {
    $issues.Add((New-Issue -Severity "error" -Code "attachment_id_missing" -Message "Missing or invalid attachmentId in $($match.sourceFile)"))
}
if ([string]::IsNullOrWhiteSpace($attachmentKey)) {
    $issues.Add((New-Issue -Severity "error" -Code "attachment_key_missing" -Message "Missing attachmentKey in $($match.sourceFile)"))
}
if ([string]::IsNullOrWhiteSpace($parentItemKey)) {
    $issues.Add((New-Issue -Severity "error" -Code "parent_item_key_missing" -Message "Missing parentItemKey in $($match.sourceFile)"))
}

$cacheDirectoryName = Split-Path -Leaf $cacheDirectory
if ($cacheDirectoryName -match "^\d+$" -and $attachmentId -gt 0 -and [string]$attachmentId -ne $cacheDirectoryName) {
    $issues.Add((New-Issue -Severity "error" -Code "attachment_id_directory_mismatch" -Message "Cache directory $cacheDirectoryName does not match attachmentId $attachmentId"))
}

$cacheHealth = Test-MineruCacheHealth -CacheDirectory $cacheDirectory
foreach ($cacheIssue in $cacheHealth.issues) {
    $issues.Add($cacheIssue)
}

$storageDirectory = if ([string]::IsNullOrWhiteSpace($attachmentKey)) { $null } else { Join-Path $storageRoot $attachmentKey }
$storagePdfs = @()
if ($null -ne $storageDirectory -and (Test-Path -LiteralPath $storageDirectory -PathType Container)) {
    $storagePdfs = @(Get-ChildItem -LiteralPath $storageDirectory -File -Filter "*.pdf")
}
if ($storagePdfs.Count -ne 1) {
    $issues.Add((New-Issue -Severity "error" -Code "storage_pdf_count" -Message "Expected exactly one PDF in $storageDirectory, found $($storagePdfs.Count)"))
}

$errorCount = @($issues | Where-Object { $_.severity -eq "error" }).Count
$result = [pscustomobject]@{
    status = if ($errorCount -eq 0) { "ok" } else { "error" }
    requestedKey = $normalizedKey
    matchKind = $match.matchKind
    zoteroDataDir = $resolvedZoteroDataDir
    mineruRoot = $mineruRoot
    cacheDirectory = $cacheDirectory
    attachmentId = $attachmentId
    attachmentKey = $attachmentKey
    parentItemKey = $parentItemKey
    sourceFilename = $sourceFilename
    fullMdPath = $cacheHealth.fullMdPath
    manifestPath = $cacheHealth.manifestPath
    contentListPath = $cacheHealth.contentListPath
    zoteroStoragePdf = if ($storagePdfs.Count -eq 1) { $storagePdfs[0].FullName } else { $null }
    health = [pscustomobject]@{
        usableForMarkdownReading = $errorCount -eq 0
        fullMdUtf16Length = $cacheHealth.fullMdUtf16Length
        manifestTotalChars = $cacheHealth.manifestTotalChars
        sectionCount = $cacheHealth.sectionCount
        readWholeMarkdown = $cacheHealth.readWholeMarkdown
    }
    issues = $issues
    invalidProvenanceWarnings = $invalidProvenance
}

$result | ConvertTo-Json -Depth 8

if ($errorCount -gt 0) {
    exit 2
}
