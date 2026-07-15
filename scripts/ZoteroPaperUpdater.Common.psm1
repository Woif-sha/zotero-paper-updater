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

function Resolve-ZoteroDataDirectory {
    param([string]$RequestedPath)

    $candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $candidates.Add($RequestedPath)
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:ZOTERO_DATA_DIR)) {
        $candidates.Add($env:ZOTERO_DATA_DIR)
    }
    else {
        $candidates.Add("E:\ZoteroData")
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw "Zotero data directory not found. Pass -ZoteroDataDir or set ZOTERO_DATA_DIR. Checked: $($candidates -join ', ')"
}

function Get-OptionalPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    $property.Value
}

function Test-MineruCacheHealth {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CacheDirectory
    )

    if (-not (Test-Path -LiteralPath $CacheDirectory -PathType Container)) {
        throw "MinerU cache directory not found: $CacheDirectory"
    }

    $issues = [System.Collections.Generic.List[object]]::new()
    $fullMdPath = Join-Path $CacheDirectory "full.md"
    $manifestPath = Join-Path $CacheDirectory "manifest.json"
    $contentListPath = Join-Path $CacheDirectory "content_list.json"
    $mdLength = $null
    $manifest = $null
    $manifestTotalChars = $null
    $manifestCharCountMatches = $null
    $sectionCount = 0

    if (-not (Test-Path -LiteralPath $fullMdPath -PathType Leaf)) {
        $issues.Add((New-Issue -Severity "error" -Code "missing_full_md" -Message "Missing full.md: $fullMdPath"))
    }
    else {
        try {
            $mdText = [System.IO.File]::ReadAllText($fullMdPath)
            $mdLength = $mdText.Length
            if ([string]::IsNullOrWhiteSpace($mdText)) {
                $issues.Add((New-Issue -Severity "error" -Code "empty_full_md" -Message "full.md is empty or whitespace-only: $fullMdPath"))
            }
        }
        catch {
            $issues.Add((New-Issue -Severity "error" -Code "unreadable_full_md" -Message "$($fullMdPath): $($_.Exception.Message)"))
        }
    }

    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        $issues.Add((New-Issue -Severity "error" -Code "missing_manifest" -Message "Missing manifest.json: $manifestPath"))
    }
    else {
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            $totalCharsValue = Get-OptionalPropertyValue -Object $manifest -Name "totalChars"
            if ($null -ne $totalCharsValue) {
                $manifestTotalChars = [long]$totalCharsValue
                if ($null -ne $mdLength) {
                    $manifestCharCountMatches = $manifestTotalChars -eq $mdLength
                    if (-not $manifestCharCountMatches) {
                        $issues.Add((New-Issue -Severity "error" -Code "manifest_char_count_mismatch" -Message "manifest.totalChars=$manifestTotalChars but full.md UTF-16 length=$mdLength in $CacheDirectory"))
                    }
                }
            }

            $sectionsValue = Get-OptionalPropertyValue -Object $manifest -Name "sections"
            $sections = @()
            if ($null -ne $sectionsValue) {
                $sections = @($sectionsValue)
            }
            $sectionCount = $sections.Count
            if ($null -ne $mdLength) {
                foreach ($section in $sections) {
                    $charStartValue = Get-OptionalPropertyValue -Object $section -Name "charStart"
                    $charEndValue = Get-OptionalPropertyValue -Object $section -Name "charEnd"
                    if ($null -eq $charStartValue -or $null -eq $charEndValue) {
                        continue
                    }
                    $sectionStart = [long]$charStartValue
                    $sectionEnd = [long]$charEndValue
                    if ($sectionStart -lt 0 -or $sectionEnd -lt $sectionStart -or $sectionEnd -gt $mdLength) {
                        $heading = [string](Get-OptionalPropertyValue -Object $section -Name "heading")
                        $issues.Add((New-Issue -Severity "error" -Code "manifest_section_range_invalid" -Message "Section '$heading' has range [$sectionStart,$sectionEnd) outside full.md length $mdLength in $CacheDirectory"))
                    }
                }

                $figureBlocksValue = Get-OptionalPropertyValue -Object $manifest -Name "figureBlocks"
                $figureBlocks = @()
                if ($null -ne $figureBlocksValue) {
                    $figureBlocks = @($figureBlocksValue)
                }
                foreach ($block in $figureBlocks) {
                    $ranges = @(
                        @("markdown", (Get-OptionalPropertyValue -Object $block -Name "markdownStart"), (Get-OptionalPropertyValue -Object $block -Name "markdownEnd")),
                        @("context", (Get-OptionalPropertyValue -Object $block -Name "contextStart"), (Get-OptionalPropertyValue -Object $block -Name "contextEnd"))
                    )
                    foreach ($range in $ranges) {
                        if ($null -eq $range[1] -or $null -eq $range[2]) {
                            continue
                        }
                        $rangeStart = [long]$range[1]
                        $rangeEnd = [long]$range[2]
                        if ($rangeStart -lt 0 -or $rangeEnd -lt $rangeStart -or $rangeEnd -gt $mdLength) {
                            $blockId = [string](Get-OptionalPropertyValue -Object $block -Name "blockId")
                            $issues.Add((New-Issue -Severity "warning" -Code "manifest_figure_range_invalid" -Message "Figure block '$blockId' has $($range[0]) range [$rangeStart,$rangeEnd) outside full.md length $mdLength in $CacheDirectory"))
                        }
                    }
                }
            }
        }
        catch {
            $issues.Add((New-Issue -Severity "error" -Code "invalid_manifest_json" -Message "$($manifestPath): $($_.Exception.Message)"))
        }
    }

    if (-not (Test-Path -LiteralPath $contentListPath -PathType Leaf)) {
        $issues.Add((New-Issue -Severity "warning" -Code "missing_content_list" -Message "content_list.json is absent; text remains readable but figure/table metadata may be incomplete"))
    }

    [pscustomobject]@{
        fullMdPath = $fullMdPath
        fullMdUtf16Length = $mdLength
        manifestPath = $manifestPath
        manifestTotalChars = $manifestTotalChars
        manifestCharCountMatches = $manifestCharCountMatches
        contentListPath = if (Test-Path -LiteralPath $contentListPath -PathType Leaf) { $contentListPath } else { $null }
        sectionCount = $sectionCount
        readWholeMarkdown = $sectionCount -eq 0
        issues = $issues
    }
}

Export-ModuleMember -Function New-Issue, Resolve-ZoteroDataDirectory, Get-OptionalPropertyValue, Test-MineruCacheHealth
