[CmdletBinding()]
param(
    [string]$ProfileDir,

    [string]$UpdateManifestUrl = "https://github.com/yilewang/llm-for-zotero/releases/download/release/update.json",

    [int]$TimeoutSec = 20,

    [switch]$RequireLatest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "ZoteroPaperUpdater.Common.psm1") -Force

$addonId = "zotero-llm@github.com.yilewang"
$upstreamRepository = "https://github.com/yilewang/llm-for-zotero"

function Resolve-ZoteroProfile {
    param([string]$RequestedProfile)

    if (-not [string]::IsNullOrWhiteSpace($RequestedProfile)) {
        $extensionsPath = Join-Path $RequestedProfile "extensions.json"
        if (-not (Test-Path -LiteralPath $extensionsPath -PathType Leaf)) {
            throw "Zotero extensions.json not found in profile: $RequestedProfile"
        }
        return (Resolve-Path -LiteralPath $RequestedProfile).Path
    }

    if ([string]::IsNullOrWhiteSpace($env:APPDATA)) {
        throw "APPDATA is unavailable; pass -ProfileDir explicitly"
    }
    $profilesRoot = Join-Path $env:APPDATA "Zotero\Zotero\Profiles"
    if (-not (Test-Path -LiteralPath $profilesRoot -PathType Container)) {
        throw "Zotero profiles root not found: $profilesRoot"
    }

    $candidates = @(
        Get-ChildItem -LiteralPath $profilesRoot -Directory |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "extensions.json") -PathType Leaf } |
            Sort-Object { (Get-Item -LiteralPath (Join-Path $_.FullName "extensions.json")).LastWriteTimeUtc } -Descending
    )
    foreach ($candidate in $candidates) {
        $extensions = Get-Content -LiteralPath (Join-Path $candidate.FullName "extensions.json") -Raw | ConvertFrom-Json
        $addonsValue = Get-OptionalPropertyValue -Object $extensions -Name "addons"
        $addons = @()
        if ($null -ne $addonsValue) {
            $addons = @($addonsValue)
        }
        if (@($addons | Where-Object { [string]$_.id -eq $addonId }).Count -gt 0) {
            return $candidate.FullName
        }
    }

    throw "Installed llm-for-zotero add-on not found in Zotero profiles under $profilesRoot"
}

function Read-InstalledManifest {
    param([string]$AddonPath)

    if (Test-Path -LiteralPath $AddonPath -PathType Container) {
        $manifestPath = Join-Path $AddonPath "manifest.json"
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            throw "Installed add-on manifest not found: $manifestPath"
        }
        return Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    }

    if (-not (Test-Path -LiteralPath $AddonPath -PathType Leaf)) {
        throw "Installed add-on path not found: $AddonPath"
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($AddonPath)
    try {
        $entry = $archive.GetEntry("manifest.json")
        if ($null -eq $entry) {
            throw "manifest.json is missing from installed XPI: $AddonPath"
        }
        $reader = [System.IO.StreamReader]::new($entry.Open(), [System.Text.Encoding]::UTF8)
        try {
            return $reader.ReadToEnd() | ConvertFrom-Json
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Convert-StableVersion {
    param([string]$Value)

    $normalized = $Value.Trim().TrimStart("v")
    $parsed = $null
    if ([System.Version]::TryParse($normalized, [ref]$parsed)) {
        return $parsed
    }
    $null
}

$resolvedProfile = Resolve-ZoteroProfile -RequestedProfile $ProfileDir
$extensionsPath = Join-Path $resolvedProfile "extensions.json"
$extensions = Get-Content -LiteralPath $extensionsPath -Raw | ConvertFrom-Json
$addonsValue = Get-OptionalPropertyValue -Object $extensions -Name "addons"
$addons = @()
if ($null -ne $addonsValue) {
    $addons = @($addonsValue)
}
$installedMatches = @($addons | Where-Object { [string]$_.id -eq $addonId })
if ($installedMatches.Count -ne 1) {
    throw "Expected one installed $addonId entry in $extensionsPath, found $($installedMatches.Count)"
}
$installed = $installedMatches[0]
$installedVersion = [string]$installed.version
$installedPath = [string]$installed.path
$installedActive = [bool]$installed.active

$installedManifest = Read-InstalledManifest -AddonPath $installedPath
$applications = Get-OptionalPropertyValue -Object $installedManifest -Name "applications"
if ($null -eq $applications) {
    throw "Installed add-on manifest has no applications section: $installedPath"
}
$zoteroApplication = Get-OptionalPropertyValue -Object $applications -Name "zotero"
if ($null -eq $zoteroApplication) {
    throw "Installed add-on manifest has no Zotero application section: $installedPath"
}
$configuredUpdateUrl = [string](Get-OptionalPropertyValue -Object $zoteroApplication -Name "update_url")

$updateManifest = Invoke-RestMethod -Uri $UpdateManifestUrl -TimeoutSec $TimeoutSec -Headers @{
    "Accept" = "application/json"
    "User-Agent" = "zotero-paper-updater/1.0"
}
$manifestAddons = Get-OptionalPropertyValue -Object $updateManifest -Name "addons"
if ($null -eq $manifestAddons) {
    throw "Official update manifest has no addons object: $UpdateManifestUrl"
}
$upstreamAddon = Get-OptionalPropertyValue -Object $manifestAddons -Name $addonId
if ($null -eq $upstreamAddon) {
    throw "Official update manifest has no entry for $addonId"
}
$updatesValue = Get-OptionalPropertyValue -Object $upstreamAddon -Name "updates"
$updates = @()
if ($null -ne $updatesValue) {
    $updates = @($updatesValue)
}
if ($updates.Count -eq 0) {
    throw "Official update manifest contains no stable updates for $addonId"
}

$latestUpdate = $updates |
    Sort-Object {
        $parsed = Convert-StableVersion -Value ([string]$_.version)
        if ($null -eq $parsed) { [version]"0.0" } else { $parsed }
    } -Descending |
    Select-Object -First 1
$latestVersion = [string]$latestUpdate.version
$installedParsed = Convert-StableVersion -Value $installedVersion
$latestParsed = Convert-StableVersion -Value $latestVersion
$isLatest = if ($null -ne $installedParsed -and $null -ne $latestParsed) {
    $installedParsed -ge $latestParsed
}
else {
    $installedVersion -eq $latestVersion
}
$updateAvailable = -not $isLatest
$updateUrlMatches = $configuredUpdateUrl -eq $UpdateManifestUrl
$isCompliant = $installedActive -and $isLatest -and $updateUrlMatches

$status = if (-not $installedActive) {
    "inactive"
}
elseif (-not $updateUrlMatches) {
    "update_channel_mismatch"
}
elseif ($updateAvailable) {
    "update_available"
}
else {
    "current"
}

$result = [pscustomobject]@{
    checkedAt = (Get-Date).ToUniversalTime().ToString("o")
    status = $status
    compliant = $isCompliant
    upstreamRepository = $upstreamRepository
    updateManifestUrl = $UpdateManifestUrl
    profileDir = $resolvedProfile
    addonId = $addonId
    installed = [pscustomobject]@{
        version = $installedVersion
        active = $installedActive
        path = $installedPath
        configuredUpdateUrl = $configuredUpdateUrl
    }
    latest = [pscustomobject]@{
        version = $latestVersion
        xpiUrl = [string]$latestUpdate.update_link
        xpiHash = [string]$latestUpdate.update_hash
        releaseUrl = "$upstreamRepository/releases/tag/v$latestVersion"
    }
    updateAvailable = $updateAvailable
    zoteroAutoUpdateConfigured = $updateUrlMatches
}

$result | ConvertTo-Json -Depth 8

if ($RequireLatest -and -not $isCompliant) {
    exit 2
}
