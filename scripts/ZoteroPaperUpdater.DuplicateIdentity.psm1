Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "ZoteroPaperUpdater.Common.psm1") -DisableNameChecking

function ConvertTo-DuplicateDoi {
    param([AllowNull()][string]$Doi)

    if ([string]::IsNullOrWhiteSpace($Doi)) { return $null }
    ($Doi.Trim() -replace "^(?i:https?://(?:dx\.)?doi\.org/)", "").ToLowerInvariant()
}

function ConvertTo-DuplicateText {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
    (($Value.Trim() -replace "\s+", " ").Normalize(
        [Text.NormalizationForm]::FormKC
    )).ToLowerInvariant()
}

function Get-DuplicateDiscoveryKey {
    param([Parameter(Mandatory = $true)][object]$Member)

    $doi = ConvertTo-DuplicateDoi -Doi (
        [string](Get-OptionalPropertyValue -Object $Member.parent -Name "doi")
    )
    if (-not [string]::IsNullOrWhiteSpace($doi)) { return "doi:$doi" }
    $parent = $Member.parent
    $creators = @(
        @($parent.creators) | ForEach-Object {
            $name = [string](Get-OptionalPropertyValue -Object $_ -Name "name")
            if ([string]::IsNullOrWhiteSpace($name)) {
                $name = @(
                    [string](Get-OptionalPropertyValue -Object $_ -Name "firstName")
                    [string](Get-OptionalPropertyValue -Object $_ -Name "lastName")
                ) -join " "
            }
            if ([string]::IsNullOrWhiteSpace($name)) { $name = [string]$_ }
            ConvertTo-DuplicateText -Value $name
        }
    ) -join [char]0x1f
    $context = @(
        "publicationTitle", "bookTitle", "conferenceName", "publisher",
        "date", "volume", "issue", "pages"
    ) | ForEach-Object {
        ConvertTo-DuplicateText -Value (
            [string](Get-OptionalPropertyValue -Object $parent -Name $_)
        )
    } | Join-String -Separator ([char]0x1f)
    @(
        "metadata"
        ConvertTo-DuplicateText -Value ([string]$parent.title)
        $creators
        $context
        [bool]$Member.cache.healthy
        [string]$Member.cache.fullMdSha256
    ) -join [char]0x1e
}

function Get-DuplicateIdentityEvidence {
    param([Parameter(Mandatory = $true)][object[]]$Members)

    $keys = @($Members | ForEach-Object { Get-DuplicateDiscoveryKey -Member $_ })
    if (@($keys | Sort-Object -Unique).Count -ne 1) {
        return [pscustomobject]@{
            status = "blocked"
            code = "strict_duplicate_identity_unproven"
            message = "The complete strict duplicate identity evidence does not match."
        }
    }
    if ($keys[0].StartsWith("doi:", [StringComparison]::Ordinal)) {
        return [pscustomobject][ordered]@{
            status = "eligible"
            kind = "doi"
            doi = $keys[0].Substring(4)
        }
    }
    if (@($Members | Where-Object {
        -not [bool]$_.cache.healthy -or
        [string]::IsNullOrWhiteSpace([string]$_.cache.fullMdSha256)
    }).Count -gt 0) {
        return [pscustomobject]@{
            status = "blocked"
            code = "strict_duplicate_identity_unproven"
            message = "Healthy MinerU content is required for metadata identity."
        }
    }
    [pscustomobject][ordered]@{
        status = "eligible"
        kind = "metadata_and_mineru"
        discoveryKey = $keys[0]
        fullMdSha256 = [string]$Members[0].cache.fullMdSha256
    }
}

Export-ModuleMember -Function `
    ConvertTo-DuplicateDoi, `
    ConvertTo-DuplicateText, `
    Get-DuplicateDiscoveryKey, `
    Get-DuplicateIdentityEvidence
