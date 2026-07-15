[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PaperRoot,

    [Parameter(Mandatory = $true)]
    [string]$ZoteroDataDir,

    [string]$ZoteroApiBase = "http://127.0.0.1:23119/api/users/0",

    [switch]$SkipHash,

    [switch]$SkipApi,

    [switch]$AllowIncomplete
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function New-Issue {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("error", "warning")]
        [string]$Severity,

        [Parameter(Mandatory = $true)]
        [string]$Code,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    [pscustomobject]@{
        severity = $Severity
        code = $Code
        message = $Message
    }
}

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
$resolvedZoteroDataDir = Resolve-ExistingDirectory -Path $ZoteroDataDir -Label "Zotero data directory"
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
        $globalIssues.Add((New-Issue -Severity "warning" -Code "invalid_provenance_json" -Message "$($sourceFile.FullName): $($_.Exception.Message)"))
        continue
    }

    $attachmentKey = [string]$source.attachmentKey
    $parentItemKey = [string]$source.parentItemKey
    if ([string]::IsNullOrWhiteSpace($attachmentKey)) {
        $globalIssues.Add((New-Issue -Severity "warning" -Code "missing_attachment_key" -Message "$($sourceFile.FullName) has no attachmentKey"))
        continue
    }
    if ([string]::IsNullOrWhiteSpace($parentItemKey)) {
        $cacheIssues.Add((New-Issue -Severity "error" -Code "missing_parent_item_key" -Message "$($sourceFile.FullName) has no parentItemKey"))
    }

    $cacheDirectoryName = Split-Path -Leaf $cacheDir
    if (
        $cacheDirectoryName -match "^\d+$" -and
        $null -ne $source.attachmentId -and
        [string]$source.attachmentId -ne $cacheDirectoryName
    ) {
        $cacheIssues.Add((New-Issue -Severity "error" -Code "attachment_id_directory_mismatch" -Message "Cache directory $cacheDirectoryName does not match provenance attachmentId $($source.attachmentId)"))
    }

    $fullMdPath = Join-Path $cacheDir "full.md"
    $manifestPath = Join-Path $cacheDir "manifest.json"
    $mdLength = $null
    $manifestTotalChars = $null
    $manifestCharCountMatches = $null

    if (-not (Test-Path -LiteralPath $fullMdPath -PathType Leaf)) {
        $cacheIssues.Add((New-Issue -Severity "error" -Code "missing_full_md" -Message "Missing full.md: $fullMdPath"))
    }
    else {
        try {
            $mdText = [System.IO.File]::ReadAllText($fullMdPath)
            $mdLength = $mdText.Length
            if ($mdLength -eq 0) {
                $cacheIssues.Add((New-Issue -Severity "error" -Code "empty_full_md" -Message "full.md is empty: $fullMdPath"))
            }
        }
        catch {
            $cacheIssues.Add((New-Issue -Severity "error" -Code "unreadable_full_md" -Message "$($fullMdPath): $($_.Exception.Message)"))
        }
    }

    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        $cacheIssues.Add((New-Issue -Severity "error" -Code "missing_manifest" -Message "Missing manifest.json: $manifestPath"))
    }
    else {
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            if ($null -ne $manifest.totalChars) {
                $manifestTotalChars = [long]$manifest.totalChars
                if ($null -ne $mdLength) {
                    $manifestCharCountMatches = $manifestTotalChars -eq $mdLength
                    if (-not $manifestCharCountMatches) {
                        $cacheIssues.Add((New-Issue -Severity "error" -Code "manifest_char_count_mismatch" -Message "manifest.totalChars=$manifestTotalChars but full.md UTF-16 length=$mdLength in $cacheDir"))
                    }
                }
            }

            if ($null -ne $mdLength) {
                foreach ($section in @($manifest.sections)) {
                    if (
                        $null -ne $section.charStart -and
                        $null -ne $section.charEnd
                    ) {
                        $sectionStart = [long]$section.charStart
                        $sectionEnd = [long]$section.charEnd
                        if (
                            $sectionStart -lt 0 -or
                            $sectionEnd -lt $sectionStart -or
                            $sectionEnd -gt $mdLength
                        ) {
                            $heading = [string]$section.heading
                            $cacheIssues.Add((New-Issue -Severity "error" -Code "manifest_section_range_invalid" -Message "Section '$heading' has range [$sectionStart,$sectionEnd) outside full.md length $mdLength in $cacheDir"))
                        }
                    }
                }

                foreach ($block in @($manifest.figureBlocks)) {
                    $ranges = @(
                        @("markdown", $block.markdownStart, $block.markdownEnd),
                        @("context", $block.contextStart, $block.contextEnd)
                    )
                    foreach ($range in $ranges) {
                        if ($null -eq $range[1] -or $null -eq $range[2]) {
                            continue
                        }
                        $rangeStart = [long]$range[1]
                        $rangeEnd = [long]$range[2]
                        if (
                            $rangeStart -lt 0 -or
                            $rangeEnd -lt $rangeStart -or
                            $rangeEnd -gt $mdLength
                        ) {
                            $blockId = [string]$block.blockId
                            $cacheIssues.Add((New-Issue -Severity "warning" -Code "manifest_figure_range_invalid" -Message "Figure block '$blockId' has $($range[0]) range [$rangeStart,$rangeEnd) outside full.md length $mdLength in $cacheDir"))
                        }
                    }
                }
            }
        }
        catch {
            $cacheIssues.Add((New-Issue -Severity "error" -Code "invalid_manifest_json" -Message "$($manifestPath): $($_.Exception.Message)"))
        }
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
        attachmentId = $source.attachmentId
        attachmentKey = $attachmentKey
        parentItemKey = $parentItemKey
        sourceFilename = [string]$source.sourceFilename
        fullMdPath = $fullMdPath
        fullMdUtf16Length = $mdLength
        manifestPath = $manifestPath
        manifestTotalChars = $manifestTotalChars
        manifestCharCountMatches = $manifestCharCountMatches
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
            $recordIssues.Add((New-Issue -Severity "error" -Code "rename_required" -Message "Local filename '$($localPdf.Name)' must become '$($match.zoteroFilename)'"))
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

$recordErrorCount = @(
    $records |
        ForEach-Object { $_.issues } |
        Where-Object { $_.severity -eq "error" }
).Count
$globalErrorCount = @($globalIssues | Where-Object { $_.severity -eq "error" }).Count
$blockingErrorCount = $recordErrorCount + $globalErrorCount
$okCount = @($records | Where-Object { $_.status -eq "ok" }).Count
$renameRequiredCount = @($records | Where-Object { $_.status -eq "rename_required" }).Count

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
        allowIncomplete = [bool]$AllowIncomplete
    }
    summary = [pscustomobject]@{
        localPdfCount = $localPdfs.Count
        mineruCacheCount = $sourceFiles.Count
        cacheCandidatesWithAttachmentKey = $cacheCandidates.Count
        mappedRecordCount = @($records | Where-Object { $null -ne $_.attachmentKey }).Count
        okCount = $okCount
        renameRequiredCount = $renameRequiredCount
        blockingErrorCount = $blockingErrorCount
    }
    records = $records
    globalIssues = $globalIssues
}

$result | ConvertTo-Json -Depth 10

if (-not $AllowIncomplete -and $blockingErrorCount -gt 0) {
    exit 2
}
