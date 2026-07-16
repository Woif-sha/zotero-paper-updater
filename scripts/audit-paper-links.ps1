[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PaperRoot,

    [string]$ZoteroDataDir,

    [string]$ZoteroApiBase = "http://127.0.0.1:23119/api/users/0",

    [switch]$SkipHash,

    [switch]$SkipApi,

    [switch]$RequireAllCaches,

    [switch]$AllowIncomplete
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "ZoteroPaperUpdater.Common.psm1") -Force

function Resolve-ExistingDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Label does not exist or is not a directory: $Path"
    }

    (Resolve-Path -LiteralPath $Path).Path
}

function Test-MetadataGapDocumented {
    param(
        [string]$Extra,
        [Parameter(Mandatory = $true)]
        [string]$Field
    )

    if ([string]::IsNullOrWhiteSpace($Extra)) {
        return $false
    }

    $normalized = $Extra.ToLowerInvariant()
    $hasStatusContext =
        $normalized.Contains("metadata status checked") -or
        $normalized.Contains("not publicly registered") -or
        $normalized.Contains("not available") -or
        $normalized.Contains("unavailable") -or
        $normalized.Contains("尚未公开") -or
        $normalized.Contains("未公开") -or
        $normalized.Contains("无可核验")
    if (-not $hasStatusContext) {
        return $false
    }
    $hasCheckDate = $normalized -match "\b(?:19|20)\d{2}-\d{2}-\d{2}\b"
    $hasSource =
        $normalized.Contains("source:") -or
        $normalized.Contains("source：") -or
        $normalized.Contains("来源:") -or
        $normalized.Contains("来源：")
    if (-not $hasCheckDate -or -not $hasSource) {
        return $false
    }

    $aliases = @{
        publicationTitle = @("publicationtitle", "journal", "期刊")
        bookTitle = @("booktitle", "book title", "书名")
        proceedingsTitle = @("proceedingstitle", "proceedings", "论文集")
        conferenceName = @("conferencename", "conference", "会议")
        volume = @("volume", "卷")
        issue = @("issue", "期")
        pages = @("pages", "pagination", "page range", "页码")
        DOI = @("doi")
        url = @("url", "official page", "官网")
        language = @("language", "语言")
        publisher = @("publisher", "出版社")
        place = @("place", "eventplace", "地点")
        ISSN = @("issn")
        ISBN = @("isbn")
        institution = @("institution", "机构")
        reportNumber = @("reportnumber", "report number", "报告编号")
        university = @("university", "大学")
        repository = @("repository", "archive", "预印本平台")
        archiveID = @("archiveid", "archive id", "预印本编号")
    }

    $fieldAliases = $aliases[$Field]
    if ($null -eq $fieldAliases) {
        $fieldAliases = @($Field.ToLowerInvariant())
    }
    foreach ($alias in $fieldAliases) {
        if ($normalized.Contains([string]$alias)) {
            return $true
        }
    }
    $false
}

function Get-RecommendedMetadataFields {
    param([string]$ItemType)

    $common = @("language", "url")
    $byType = @{
        journalArticle = @("publicationTitle", "volume", "issue", "pages", "DOI", "ISSN")
        conferencePaper = @("proceedingsTitle", "conferenceName", "publisher", "place", "pages", "DOI")
        bookSection = @("bookTitle", "publisher", "place", "pages", "ISBN", "DOI")
        book = @("publisher", "place", "ISBN", "DOI")
        report = @("institution", "reportNumber", "place", "DOI")
        thesis = @("university", "place", "DOI")
        preprint = @("repository", "archiveID", "DOI")
    }

    $specific = $byType[$ItemType]
    if ($null -eq $specific) {
        $specific = @("DOI")
    }
    @($common + $specific | Select-Object -Unique)
}

function Get-MetadataAudit {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ParentData
    )

    $issues = [System.Collections.Generic.List[object]]::new()
    $missingCore = [System.Collections.Generic.List[string]]::new()
    $missingRecommended = [System.Collections.Generic.List[string]]::new()
    $documentedUnavailable = [System.Collections.Generic.List[string]]::new()
    $unresolved = [System.Collections.Generic.List[string]]::new()

    $itemType = [string](Get-OptionalPropertyValue -Object $ParentData -Name "itemType")
    $title = [string](Get-OptionalPropertyValue -Object $ParentData -Name "title")
    $date = [string](Get-OptionalPropertyValue -Object $ParentData -Name "date")
    $creatorsValue = Get-OptionalPropertyValue -Object $ParentData -Name "creators"
    $creators = @()
    if ($null -ne $creatorsValue) {
        $creators = @($creatorsValue)
    }
    $extra = [string](Get-OptionalPropertyValue -Object $ParentData -Name "extra")

    if ([string]::IsNullOrWhiteSpace($title)) {
        $missingCore.Add("title")
    }
    if ($creators.Count -eq 0) {
        $missingCore.Add("creators")
    }
    if ([string]::IsNullOrWhiteSpace($date)) {
        $missingCore.Add("date")
    }

    foreach ($field in (Get-RecommendedMetadataFields -ItemType $itemType)) {
        $value = Get-OptionalPropertyValue -Object $ParentData -Name $field
        $isMissing = $null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)
        if (-not $isMissing) {
            continue
        }

        $missingRecommended.Add($field)
        if (Test-MetadataGapDocumented -Extra $extra -Field $field) {
            $documentedUnavailable.Add($field)
            $issues.Add((New-Issue -Severity "warning" -Code "metadata_gap_documented" -Message "$field is empty but its unavailable status is documented in Extra"))
        }
        else {
            $unresolved.Add($field)
            $issues.Add((New-Issue -Severity "error" -Code "metadata_research_required" -Message "$field is empty and has no dated, sourced availability note in Extra"))
        }
    }

    if ($missingCore.Count -gt 0) {
        $issues.Add((New-Issue -Severity "error" -Code "metadata_core_missing" -Message "Missing core Zotero metadata: $($missingCore -join ', ')"))
    }

    [pscustomobject]@{
        status = if ($missingCore.Count -gt 0) {
            "incomplete_core"
        }
        elseif ($unresolved.Count -gt 0) {
            "needs_research"
        }
        elseif ($documentedUnavailable.Count -gt 0) {
            "documented_gaps"
        }
        else {
            "complete"
        }
        itemType = $itemType
        missingCoreFields = $missingCore
        missingRecommendedFields = $missingRecommended
        documentedUnavailableFields = $documentedUnavailable
        unresolvedFields = $unresolved
        issues = $issues
    }
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

    $fullPath.Equals(
        $fullRoot,
        [System.StringComparison]::OrdinalIgnoreCase
    ) -or $fullPath.StartsWith(
        $rootPrefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

$resolvedPaperRoot = Resolve-ExistingDirectory -Path $PaperRoot -Label "Paper root"
$resolvedZoteroDataDir = Resolve-ZoteroDataDirectory -RequestedPath $ZoteroDataDir
$mineruRoot = Join-Path $resolvedZoteroDataDir "llm-for-zotero-mineru"
$storageRoot = Join-Path $resolvedZoteroDataDir "storage"
$resolvedMineruRoot = Resolve-ExistingDirectory -Path $mineruRoot -Label "MinerU root"
$resolvedStorageRoot = Resolve-ExistingDirectory -Path $storageRoot -Label "Zotero storage root"

$hashCache = @{}
function Get-CachedSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $cacheKey = $resolved.ToLowerInvariant()
    if (-not $hashCache.ContainsKey($cacheKey)) {
        $hashCache[$cacheKey] = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash
    }
    $hashCache[$cacheKey]
}

$globalIssues = [System.Collections.Generic.List[object]]::new()
$cacheCandidates = [System.Collections.Generic.List[object]]::new()
$apiHeaders = @{
    "Zotero-API-Version" = "3"
    "Accept-Encoding" = "identity"
    "User-Agent" = "zotero-paper-updater/1.0"
}
$sourceFiles = @(
    Get-ChildItem -LiteralPath $resolvedMineruRoot -Recurse -File -Filter "_llm_source.json"
)

foreach ($sourceFile in $sourceFiles) {
    $cacheDir = $sourceFile.Directory.FullName
    $cacheIssues = [System.Collections.Generic.List[object]]::new()
    $source = $null

    try {
        $source = Get-Content -LiteralPath $sourceFile.FullName -Raw | ConvertFrom-Json
    }
    catch {
        $severity = if ($RequireAllCaches) { "error" } else { "warning" }
        $globalIssues.Add((New-Issue -Severity $severity -Code "invalid_provenance_json" -Message "$($sourceFile.FullName): $($_.Exception.Message)"))
        continue
    }

    $kind = [string](Get-OptionalPropertyValue -Object $source -Name "kind")
    $versionValue = Get-OptionalPropertyValue -Object $source -Name "version"
    $attachmentIdValue = Get-OptionalPropertyValue -Object $source -Name "attachmentId"
    $attachmentKey = [string](Get-OptionalPropertyValue -Object $source -Name "attachmentKey")
    $parentItemKey = [string](Get-OptionalPropertyValue -Object $source -Name "parentItemKey")
    $sourceFilename = [string](Get-OptionalPropertyValue -Object $source -Name "sourceFilename")
    $origin = [string](Get-OptionalPropertyValue -Object $source -Name "origin")
    $recordedAt = [string](Get-OptionalPropertyValue -Object $source -Name "recordedAt")

    if ($kind -ne "llm-for-zotero/mineru-cache-source") {
        $cacheIssues.Add((New-Issue -Severity "error" -Code "provenance_kind_invalid" -Message "$($sourceFile.FullName) has unexpected provenance kind '$kind'"))
    }
    if ($null -eq $versionValue -or [long]$versionValue -ne 2) {
        $cacheIssues.Add((New-Issue -Severity "error" -Code "provenance_version_invalid" -Message "$($sourceFile.FullName) is not provenance version 2"))
    }
    if ($origin -ne "parsed" -and $origin -ne "restored") {
        $cacheIssues.Add((New-Issue -Severity "error" -Code "provenance_origin_invalid" -Message "$($sourceFile.FullName) has invalid origin '$origin'"))
    }
    if ([string]::IsNullOrWhiteSpace($recordedAt)) {
        $cacheIssues.Add((New-Issue -Severity "error" -Code "provenance_recorded_at_missing" -Message "$($sourceFile.FullName) has no recordedAt timestamp"))
    }
    if ([string]::IsNullOrWhiteSpace($attachmentKey)) {
        $severity = if ($RequireAllCaches) { "error" } else { "warning" }
        $globalIssues.Add((New-Issue -Severity $severity -Code "missing_attachment_key" -Message "$($sourceFile.FullName) has no attachmentKey"))
        continue
    }
    if ([string]::IsNullOrWhiteSpace($parentItemKey)) {
        $cacheIssues.Add((New-Issue -Severity "error" -Code "missing_parent_item_key" -Message "$($sourceFile.FullName) has no parentItemKey"))
    }

    $cacheDirectoryName = Split-Path -Leaf $cacheDir
    if (
        $cacheDirectoryName -match "^\d+$" -and
        $null -ne $attachmentIdValue -and
        [string]$attachmentIdValue -ne $cacheDirectoryName
    ) {
        $cacheIssues.Add((New-Issue -Severity "error" -Code "attachment_id_directory_mismatch" -Message "Cache directory $cacheDirectoryName does not match provenance attachmentId $attachmentIdValue"))
    }

    $cacheHealth = Test-MineruCacheHealth -CacheDirectory $cacheDir
    foreach ($cacheIssue in $cacheHealth.issues) {
        $cacheIssues.Add($cacheIssue)
    }

    $storageDir = Join-Path $resolvedStorageRoot $attachmentKey
    $storagePdfs = @()
    if (Test-Path -LiteralPath $storageDir -PathType Container) {
        $storagePdfs = @(Get-ChildItem -LiteralPath $storageDir -File -Filter "*.pdf")
    }
    if ($storagePdfs.Count -ne 1) {
        $cacheIssues.Add((New-Issue -Severity "error" -Code "storage_pdf_count" -Message "Expected exactly one PDF in $storageDir, found $($storagePdfs.Count)"))
    }

    $zoteroPdf = $null
    $zoteroHash = $null
    if ($storagePdfs.Count -eq 1) {
        $zoteroPdf = $storagePdfs[0].FullName
        if (-not $SkipHash) {
            try {
                $zoteroHash = Get-CachedSha256 -Path $zoteroPdf
            }
            catch {
                $cacheIssues.Add((New-Issue -Severity "error" -Code "zotero_hash_failed" -Message "$($zoteroPdf): $($_.Exception.Message)"))
            }
        }
    }

    $cacheCandidates.Add([pscustomobject]@{
        cacheDirectory = $cacheDir
        attachmentId = $attachmentIdValue
        attachmentKey = $attachmentKey
        parentItemKey = $parentItemKey
        sourceFilename = $sourceFilename
        provenanceKind = $kind
        provenanceVersion = $versionValue
        provenanceOrigin = $origin
        provenanceRecordedAt = $recordedAt
        fullMdPath = $cacheHealth.fullMdPath
        fullMdUtf16Length = $cacheHealth.fullMdUtf16Length
        manifestPath = $cacheHealth.manifestPath
        manifestTotalChars = $cacheHealth.manifestTotalChars
        manifestCharCountMatches = $cacheHealth.manifestCharCountMatches
        zoteroStoragePdf = $zoteroPdf
        zoteroFilename = if ($null -ne $zoteroPdf) { Split-Path -Leaf $zoteroPdf } else { $null }
        zoteroSha256 = $zoteroHash
        issues = $cacheIssues
    })
}

$duplicateAttachmentKeys = @(
    $cacheCandidates |
        Group-Object -Property attachmentKey |
        Where-Object { $_.Count -gt 1 }
)
foreach ($duplicate in $duplicateAttachmentKeys) {
    $globalIssues.Add((New-Issue -Severity "error" -Code "duplicate_attachment_key" -Message "attachmentKey $($duplicate.Name) occurs in $($duplicate.Count) cache records"))
}

$localPdfs = @(
    Get-ChildItem -LiteralPath $resolvedPaperRoot -Recurse -File -Filter "*.pdf" |
        Where-Object { Test-PathWithinRoot -Path $_.FullName -Root $resolvedPaperRoot }
)

if ($localPdfs.Count -eq 0) {
    $globalIssues.Add((New-Issue -Severity "error" -Code "no_local_pdfs" -Message "No PDF files found under $resolvedPaperRoot"))
}

if ($SkipHash) {
    $severity = if ($AllowIncomplete) { "warning" } else { "error" }
    $globalIssues.Add((New-Issue -Severity $severity -Code "hash_verification_skipped" -Message "SHA-256 verification was skipped; strict one-to-one identity cannot be proven"))
}

$apiAvailable = $false
if (-not $SkipApi) {
    try {
        $null = Invoke-RestMethod -Uri "$ZoteroApiBase/items?limit=1" -Headers $apiHeaders -TimeoutSec 10
        $apiAvailable = $true
    }
    catch {
        $globalIssues.Add((New-Issue -Severity "error" -Code "zotero_api_unreachable" -Message "$($ZoteroApiBase): $($_.Exception.Message)"))
    }
}
else {
    $severity = if ($AllowIncomplete) { "warning" } else { "error" }
    $globalIssues.Add((New-Issue -Severity $severity -Code "api_verification_skipped" -Message "Zotero parent-child verification was skipped"))
}

$records = [System.Collections.Generic.List[object]]::new()
$matchedAttachmentCounts = @{}

foreach ($localPdf in $localPdfs) {
    $recordIssues = [System.Collections.Generic.List[object]]::new()
    $localHash = $null
    $matches = @()
    $metadataAudit = $null
    $parentTitle = $null

    if (-not $SkipHash) {
        try {
            $localHash = Get-CachedSha256 -Path $localPdf.FullName
            $matches = @(
                $cacheCandidates |
                    Where-Object {
                        -not [string]::IsNullOrWhiteSpace([string]$_.zoteroSha256) -and
                        $_.zoteroSha256 -eq $localHash
                    }
            )
        }
        catch {
            $recordIssues.Add((New-Issue -Severity "error" -Code "local_hash_failed" -Message "$($localPdf.FullName): $($_.Exception.Message)"))
        }
    }
    else {
        $matches = @(
            $cacheCandidates |
                Where-Object { $_.zoteroFilename -eq $localPdf.Name }
        )
    }

    $match = $null
    if ($matches.Count -eq 0) {
        $recordIssues.Add((New-Issue -Severity "error" -Code "unmapped_local_pdf" -Message "No unique Zotero/MinerU attachment matches $($localPdf.FullName)"))
    }
    elseif ($matches.Count -gt 1) {
        $keys = ($matches | ForEach-Object { $_.attachmentKey }) -join ", "
        $recordIssues.Add((New-Issue -Severity "error" -Code "ambiguous_local_pdf" -Message "$($localPdf.FullName) matches multiple attachment keys: $keys"))
    }
    else {
        $match = $matches[0]
        foreach ($issue in $match.issues) {
            $recordIssues.Add($issue)
        }

        if (-not $matchedAttachmentCounts.ContainsKey($match.attachmentKey)) {
            $matchedAttachmentCounts[$match.attachmentKey] = 0
        }
        $matchedAttachmentCounts[$match.attachmentKey]++

        if ($localPdf.Name -cne $match.zoteroFilename) {
            $renameTarget = Join-Path $localPdf.DirectoryName $match.zoteroFilename
            if (Test-Path -LiteralPath $renameTarget -PathType Leaf) {
                if ($SkipHash) {
                    $recordIssues.Add((New-Issue -Severity "error" -Code "rename_target_collision_unverified" -Message "Cannot rename '$($localPdf.Name)' because target '$($match.zoteroFilename)' already exists and hashing was skipped"))
                }
                else {
                    try {
                        $targetHash = Get-CachedSha256 -Path $renameTarget
                        if ($targetHash -eq $localHash) {
                            $recordIssues.Add((New-Issue -Severity "error" -Code "rename_target_duplicate" -Message "Cannot rename '$($localPdf.Name)' because target '$($match.zoteroFilename)' already exists with identical content; cleanup requires explicit authority"))
                        }
                        else {
                            $recordIssues.Add((New-Issue -Severity "error" -Code "rename_target_collision" -Message "Cannot rename '$($localPdf.Name)' because target '$($match.zoteroFilename)' already exists with different content"))
                        }
                    }
                    catch {
                        $recordIssues.Add((New-Issue -Severity "error" -Code "rename_target_hash_failed" -Message "$renameTarget`: $($_.Exception.Message)"))
                    }
                }
            }
            else {
                $recordIssues.Add((New-Issue -Severity "error" -Code "rename_required" -Message "Local filename '$($localPdf.Name)' must become '$($match.zoteroFilename)'"))
            }
        }

        if ($apiAvailable) {
            try {
                $attachmentItem = Invoke-RestMethod -Uri "$ZoteroApiBase/items/$($match.attachmentKey)" -Headers $apiHeaders -TimeoutSec 10
                if ([string]$attachmentItem.data.itemType -ne "attachment") {
                    $recordIssues.Add((New-Issue -Severity "error" -Code "key_is_not_attachment" -Message "$($match.attachmentKey) is not a Zotero attachment"))
                }
                if ([string]$attachmentItem.data.parentItem -ne $match.parentItemKey) {
                    $recordIssues.Add((New-Issue -Severity "error" -Code "parent_relation_mismatch" -Message "Provenance parent $($match.parentItemKey) differs from Zotero parent $($attachmentItem.data.parentItem)"))
                }

                $parentItem = Invoke-RestMethod -Uri "$ZoteroApiBase/items/$($match.parentItemKey)" -Headers $apiHeaders -TimeoutSec 10
                if ([string]$parentItem.data.itemType -eq "attachment") {
                    $recordIssues.Add((New-Issue -Severity "error" -Code "parent_is_attachment" -Message "$($match.parentItemKey) resolves to an attachment, not a bibliographic parent"))
                }
                else {
                    $parentTitle = [string](Get-OptionalPropertyValue -Object $parentItem.data -Name "title")
                    $metadataAudit = Get-MetadataAudit -ParentData $parentItem.data
                    foreach ($metadataIssue in $metadataAudit.issues) {
                        $recordIssues.Add($metadataIssue)
                    }
                }
            }
            catch {
                $recordIssues.Add((New-Issue -Severity "error" -Code "zotero_item_query_failed" -Message "$($match.attachmentKey): $($_.Exception.Message)"))
            }
        }
    }

    $errorCount = @($recordIssues | Where-Object { $_.severity -eq "error" }).Count
    $status = if ($errorCount -eq 0) {
        "ok"
    }
    elseif (@($recordIssues | Where-Object { $_.code -eq "rename_required" }).Count -eq $errorCount) {
        "rename_required"
    }
    else {
        "error"
    }

    $records.Add([pscustomobject]@{
        status = $status
        localPdf = $localPdf.FullName
        localFilename = $localPdf.Name
        localSha256 = $localHash
        attachmentId = if ($null -ne $match) { $match.attachmentId } else { $null }
        attachmentKey = if ($null -ne $match) { $match.attachmentKey } else { $null }
        parentItemKey = if ($null -ne $match) { $match.parentItemKey } else { $null }
        parentTitle = $parentTitle
        metadata = $metadataAudit
        cacheDirectory = if ($null -ne $match) { $match.cacheDirectory } else { $null }
        fullMdPath = if ($null -ne $match) { $match.fullMdPath } else { $null }
        sourceFilename = if ($null -ne $match) { $match.sourceFilename } else { $null }
        zoteroStoragePdf = if ($null -ne $match) { $match.zoteroStoragePdf } else { $null }
        zoteroFilename = if ($null -ne $match) { $match.zoteroFilename } else { $null }
        zoteroSha256 = if ($null -ne $match) { $match.zoteroSha256 } else { $null }
        filenameMatches = if ($null -ne $match) { $localPdf.Name -ceq $match.zoteroFilename } else { $false }
        hashMatches = if ($SkipHash -or $null -eq $match) { $null } else { $localHash -eq $match.zoteroSha256 }
        issues = $recordIssues
    })
}

foreach ($entry in $matchedAttachmentCounts.GetEnumerator()) {
    if ($entry.Value -gt 1) {
        $globalIssues.Add((New-Issue -Severity "error" -Code "duplicate_local_attachment" -Message "attachmentKey $($entry.Key) has $($entry.Value) matching local PDF files"))
    }
}

if ($RequireAllCaches) {
    foreach ($candidate in $cacheCandidates) {
        $matchedCount = if ($matchedAttachmentCounts.ContainsKey($candidate.attachmentKey)) {
            [int]$matchedAttachmentCounts[$candidate.attachmentKey]
        }
        else {
            0
        }
        if ($matchedCount -gt 0) {
            continue
        }

        $globalIssues.Add((New-Issue -Severity "error" -Code "missing_local_pdf_for_cache" -Message "No PDF under PaperRoot matches MinerU attachmentKey $($candidate.attachmentKey)"))
        foreach ($candidateIssue in $candidate.issues) {
            $globalIssues.Add($candidateIssue)
        }
    }
}

$recordErrorCount = @(
    $records |
        ForEach-Object { $_.issues } |
        Where-Object { $_.severity -eq "error" }
).Count
$globalErrorCount = @($globalIssues | Where-Object { $_.severity -eq "error" }).Count
$blockingErrorCount = $recordErrorCount + $globalErrorCount
$okCount = @($records | Where-Object { $_.status -eq "ok" }).Count
$renameRequiredCount = @($records | Where-Object { $_.status -eq "rename_required" }).Count
$metadataAuditedCount = @($records | Where-Object { $null -ne $_.metadata }).Count
$metadataResearchRequiredCount = @(
    $records |
        Where-Object { $null -ne $_.metadata } |
        ForEach-Object { $_.metadata.unresolvedFields }
).Count
$documentedMetadataGapCount = @(
    $records |
        Where-Object { $null -ne $_.metadata } |
        ForEach-Object { $_.metadata.documentedUnavailableFields }
).Count
$unmatchedCacheCount = @(
    $cacheCandidates |
        Where-Object {
            -not $matchedAttachmentCounts.ContainsKey($_.attachmentKey) -or
            [int]$matchedAttachmentCounts[$_.attachmentKey] -eq 0
        }
).Count

$result = [pscustomobject]@{
    generatedAt = (Get-Date).ToUniversalTime().ToString("o")
    roots = [pscustomobject]@{
        paperRoot = $resolvedPaperRoot
        zoteroDataDir = $resolvedZoteroDataDir
        mineruRoot = $resolvedMineruRoot
        storageRoot = $resolvedStorageRoot
    }
    options = [pscustomobject]@{
        hashVerificationRequested = -not $SkipHash
        apiVerificationRequested = -not $SkipApi
        zoteroApiReachable = $apiAvailable
        requireAllCaches = [bool]$RequireAllCaches
        allowIncomplete = [bool]$AllowIncomplete
    }
    summary = [pscustomobject]@{
        localPdfCount = $localPdfs.Count
        mineruCacheCount = $sourceFiles.Count
        cacheCandidatesWithAttachmentKey = $cacheCandidates.Count
        mappedRecordCount = @($records | Where-Object { $null -ne $_.attachmentKey }).Count
        okCount = $okCount
        renameRequiredCount = $renameRequiredCount
        metadataAuditedCount = $metadataAuditedCount
        metadataResearchRequiredCount = $metadataResearchRequiredCount
        documentedMetadataGapCount = $documentedMetadataGapCount
        unmatchedCacheCount = $unmatchedCacheCount
        blockingErrorCount = $blockingErrorCount
    }
    records = $records
    caches = $cacheCandidates
    globalIssues = $globalIssues
}

$result | ConvertTo-Json -Depth 10

if (-not $AllowIncomplete -and $blockingErrorCount -gt 0) {
    exit 2
}
