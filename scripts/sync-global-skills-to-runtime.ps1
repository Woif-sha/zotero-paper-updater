[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$GlobalSkillsRoot = (Join-Path $HOME ".agents\skills"),
    [string]$ZoteroDataDir,
    [string]$RuntimeRoot,
    [string[]]$SkillName,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return [System.IO.Path]::GetFullPath($Path).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
}

function Test-PathWithinRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $normalizedPath = Get-NormalizedPath $Path
    $normalizedRoot = Get-NormalizedPath $Root
    return $normalizedPath.Equals($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        $normalizedPath.StartsWith(
            $normalizedRoot + [System.IO.Path]::DirectorySeparatorChar,
            [System.StringComparison]::OrdinalIgnoreCase
        )
}

function Resolve-ZoteroDataDirectory {
    if ($ZoteroDataDir) {
        return Get-NormalizedPath $ZoteroDataDir
    }
    if ($env:ZOTERO_DATA_DIR) {
        return Get-NormalizedPath $env:ZOTERO_DATA_DIR
    }
    if (Test-Path -LiteralPath "E:\ZoteroData" -PathType Container) {
        return "E:\ZoteroData"
    }
    throw "Cannot resolve Zotero data directory. Pass -ZoteroDataDir or set ZOTERO_DATA_DIR."
}

function Get-RuntimeSkillDirectories {
    param([Parameter(Mandatory = $true)][string]$Root)

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw "llm-for-zotero runtime root does not exist: $Root"
    }

    $directories = Get-ChildItem -LiteralPath $Root -Directory -Force -Recurse |
        Where-Object {
            $_.Name -eq "skills" -and
            $_.Parent -and
            $_.Parent.Name -eq ".agents"
        } |
        ForEach-Object { Get-NormalizedPath $_.FullName } |
        Sort-Object -Unique

    if (@($directories).Count -eq 0) {
        throw "No .agents\skills directory was found under $Root. Start llm-for-zotero once, or pass the updated -RuntimeRoot after an upstream layout change."
    }
    return @($directories)
}

function Get-RegisteredSkills {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string[]]$SelectedNames
    )

    $registryPath = Join-Path $Root ".skills-list.json"
    if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) {
        throw "skills-updater registry not found: $registryPath"
    }

    $registry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
    $requested = @{}
    foreach ($name in @($SelectedNames)) {
        if ($name) { $requested[$name] = $true }
    }

    $skills = foreach ($property in $registry.entries.PSObject.Properties) {
        $name = [string]$property.Name
        if ($requested.Count -gt 0 -and -not $requested.ContainsKey($name)) {
            continue
        }
        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') {
            throw "Unsafe registered skill name: $name"
        }

        $source = Get-NormalizedPath ([string]$property.Value.path)
        if (-not (Test-PathWithinRoot -Path $source -Root $Root)) {
            throw "Registered skill is outside the canonical global skills root: $name -> $source"
        }
        if (-not (Test-Path -LiteralPath (Join-Path $source "SKILL.md") -PathType Leaf)) {
            throw "Registered skill has no SKILL.md: $name -> $source"
        }

        [pscustomobject]@{ name = $name; source = $source }
        $requested.Remove($name)
    }

    if ($requested.Count -gt 0) {
        throw "Requested skills are not registered: $($requested.Keys -join ', ')"
    }
    if (@($skills).Count -eq 0) {
        throw "No registered skills were selected from $registryPath"
    }
    return @($skills | Sort-Object name)
}

function Get-LinkTargetPath {
    param([Parameter(Mandatory = $true)][System.IO.FileSystemInfo]$Item)

    $target = @($Item.Target)[0]
    if (-not $target) { return $null }
    if (-not [System.IO.Path]::IsPathRooted($target)) {
        $target = Join-Path $Item.Parent.FullName $target
    }
    return Get-NormalizedPath $target
}

$globalRoot = Get-NormalizedPath $GlobalSkillsRoot
if (-not (Test-Path -LiteralPath $globalRoot -PathType Container)) {
    throw "Global skills root does not exist: $globalRoot"
}

$resolvedRuntimeRoot = if ($RuntimeRoot) {
    Get-NormalizedPath $RuntimeRoot
}
else {
    Join-Path (Resolve-ZoteroDataDirectory) "agent-runtime"
}
$runtimeSkillDirs = Get-RuntimeSkillDirectories $resolvedRuntimeRoot
$registeredSkills = Get-RegisteredSkills -Root $globalRoot -SelectedNames $SkillName

$links = @()
$conflicts = @()
foreach ($runtimeSkillsDir in $runtimeSkillDirs) {
    foreach ($skill in $registeredSkills) {
        $destination = Join-Path $runtimeSkillsDir $skill.name
        $item = Get-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
        if (-not $item) {
            $links += [pscustomobject]@{
                skill = $skill.name
                source = $skill.source
                destination = $destination
                status = "planned"
            }
            continue
        }

        $target = Get-LinkTargetPath $item
        if ($item.LinkType -in @("SymbolicLink", "Junction") -and
            $target -and
            $target.Equals($skill.source, [System.StringComparison]::OrdinalIgnoreCase)) {
            $links += [pscustomobject]@{
                skill = $skill.name
                source = $skill.source
                destination = $destination
                status = "unchanged"
            }
            continue
        }

        $conflicts += [pscustomobject]@{
            skill = $skill.name
            destination = $destination
            existingType = if ($item.LinkType) { [string]$item.LinkType } else { "directory-or-file" }
            existingTarget = $target
        }
    }
}

$result = [ordered]@{
    globalSkillsRoot = $globalRoot
    registryPath = Join-Path $globalRoot ".skills-list.json"
    runtimeRoot = $resolvedRuntimeRoot
    runtimeSkillDirectories = $runtimeSkillDirs
    selectedSkillCount = $registeredSkills.Count
    plannedLinkCount = @($links | Where-Object status -eq "planned").Count
    createdLinkCount = 0
    unchangedLinkCount = @($links | Where-Object status -eq "unchanged").Count
    conflicts = $conflicts
    links = $links
}

if ($conflicts.Count -gt 0) {
    if ($AsJson) { $result | ConvertTo-Json -Depth 8 } else { $result }
    exit 2
}

foreach ($link in $links | Where-Object status -eq "planned") {
    if ($PSCmdlet.ShouldProcess($link.destination, "Create directory symbolic link to $($link.source)")) {
        New-Item -ItemType SymbolicLink -Path $link.destination -Target $link.source -ErrorAction Stop | Out-Null
        $link.status = "created"
        $result.createdLinkCount++
    }
}

if ($AsJson) { $result | ConvertTo-Json -Depth 8 } else { $result }
