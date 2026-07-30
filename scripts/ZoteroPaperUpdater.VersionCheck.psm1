Set-StrictMode -Version Latest

$script:AddonId = "zotero-llm@github.com.yilewang"
$script:UpdateManifestUrl = "https://github.com/yilewang/llm-for-zotero/releases/download/release/update.json"

function Resolve-LlmForZoteroProfile {
    param([string]$ProfileDir)

    if (-not [string]::IsNullOrWhiteSpace($ProfileDir)) {
        if (-not (Test-Path -LiteralPath (Join-Path $ProfileDir "extensions.json") -PathType Leaf)) {
            throw "Zotero extensions.json not found in profile: $ProfileDir"
        }
        return (Resolve-Path -LiteralPath $ProfileDir).Path
    }
    $profilesRoot = Join-Path $env:APPDATA "Zotero\Zotero\Profiles"
    $candidates = @(
        Get-ChildItem -LiteralPath $profilesRoot -Directory |
            Where-Object {
                Test-Path -LiteralPath (Join-Path $_.FullName "extensions.json") -PathType Leaf
            } |
            Sort-Object {
                (Get-Item -LiteralPath (Join-Path $_.FullName "extensions.json")).LastWriteTimeUtc
            } -Descending
    )
    foreach ($candidate in $candidates) {
        $extensions = Get-Content -LiteralPath (
            Join-Path $candidate.FullName "extensions.json"
        ) -Raw | ConvertFrom-Json
        if (@($extensions.addons | Where-Object { [string]$_.id -eq $script:AddonId }).Count -gt 0) {
            return $candidate.FullName
        }
    }
    throw "Installed llm-for-zotero add-on was not found in Zotero profiles"
}

function Read-LlmForZoteroInstalledManifest {
    param([Parameter(Mandatory = $true)][string]$AddonPath)

    if (Test-Path -LiteralPath $AddonPath -PathType Container) {
        return Get-Content -LiteralPath (Join-Path $AddonPath "manifest.json") -Raw |
            ConvertFrom-Json
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($AddonPath)
    try {
        $entry = $archive.GetEntry("manifest.json")
        if ($null -eq $entry) {
            throw "manifest.json is missing from installed XPI: $AddonPath"
        }
        $reader = [IO.StreamReader]::new($entry.Open(), [Text.Encoding]::UTF8)
        try {
            $reader.ReadToEnd() | ConvertFrom-Json
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $archive.Dispose()
    }
}

function ConvertTo-LlmForZoteroVersion {
    param([Parameter(Mandatory = $true)][string]$Value)

    $parsed = $null
    if ([version]::TryParse($Value.Trim().TrimStart("v"), [ref]$parsed)) {
        return $parsed
    }
    $null
}

function Get-LlmForZoteroVersionStatus {
    param(
        [string]$ProfileDir,

        [scriptblock]$ManifestAdapter
    )

    if ($null -eq $ManifestAdapter) {
        $ManifestAdapter = {
            Invoke-RestMethod `
                -Uri $script:UpdateManifestUrl `
                -TimeoutSec 20 `
                -Headers @{
                    Accept = "application/json"
                    "User-Agent" = "zotero-paper-updater/1.0"
                }
        }
    }

    $resolvedProfile = Resolve-LlmForZoteroProfile -ProfileDir $ProfileDir
    $extensions = Get-Content -LiteralPath (
        Join-Path $resolvedProfile "extensions.json"
    ) -Raw | ConvertFrom-Json
    $installedMatches = @(
        $extensions.addons | Where-Object { [string]$_.id -eq $script:AddonId }
    )
    if ($installedMatches.Count -ne 1) {
        throw "Expected one installed $($script:AddonId) entry"
    }
    $installed = $installedMatches[0]
    $installedManifest = Read-LlmForZoteroInstalledManifest -AddonPath ([string]$installed.path)
    $configuredUpdateUrl = [string]$installedManifest.applications.zotero.update_url
    $updateManifest = & $ManifestAdapter
    $updates = @($updateManifest.addons.($script:AddonId).updates)
    if ($updates.Count -eq 0) {
        throw "Official update manifest contains no stable updates for $($script:AddonId)"
    }
    $latest = $updates |
        Sort-Object {
            $version = ConvertTo-LlmForZoteroVersion -Value ([string]$_.version)
            if ($null -eq $version) { [version]"0.0" } else { $version }
        } -Descending |
        Select-Object -First 1
    $installedVersion = ConvertTo-LlmForZoteroVersion -Value ([string]$installed.version)
    $latestVersion = ConvertTo-LlmForZoteroVersion -Value ([string]$latest.version)
    $isLatest = if ($null -ne $installedVersion -and $null -ne $latestVersion) {
        $installedVersion -ge $latestVersion
    }
    else {
        [string]$installed.version -eq [string]$latest.version
    }
    $compliant = [bool]$installed.active -and
        $configuredUpdateUrl -eq $script:UpdateManifestUrl -and
        $isLatest

    [pscustomobject][ordered]@{
        compliant = $compliant
        installedVersion = [string]$installed.version
        latestVersion = [string]$latest.version
        active = [bool]$installed.active
        updateChannelMatches = $configuredUpdateUrl -eq $script:UpdateManifestUrl
    }
}

Export-ModuleMember -Function Get-LlmForZoteroVersionStatus
