[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repoRoot "scripts\ZoteroPaperUpdater.VersionCheck.psm1"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) (
    "zotero-version-check-test-" + [guid]::NewGuid().ToString("N")
)
$profileRoot = Join-Path $tempRoot "profile"
$addonRoot = Join-Path $tempRoot "addon"
$passed = 0

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:passed++
}

try {
    [IO.Directory]::CreateDirectory($profileRoot) | Out-Null
    [IO.Directory]::CreateDirectory($addonRoot) | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $profileRoot "extensions.json"),
        ([pscustomobject]@{
            addons = @([pscustomobject]@{
                id = "zotero-llm@github.com.yilewang"
                version = "3.8.26"
                active = $true
                path = $addonRoot
            })
        } | ConvertTo-Json -Depth 5),
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        (Join-Path $addonRoot "manifest.json"),
        ([pscustomobject]@{
            applications = [pscustomobject]@{
                zotero = [pscustomobject]@{
                    update_url = "https://github.com/yilewang/llm-for-zotero/releases/download/release/update.json"
                }
            }
        } | ConvertTo-Json -Depth 5),
        [Text.UTF8Encoding]::new($false)
    )
    $module = Import-Module -Name $modulePath -Force -PassThru
    $manifestAdapter = {
        [pscustomobject]@{
            addons = [pscustomobject]@{
                "zotero-llm@github.com.yilewang" = [pscustomobject]@{
                    updates = @([pscustomobject]@{ version = "3.8.26" })
                }
            }
        }
    }
    $status = & $module {
        param($ProfilePath, $Adapter)
        Get-LlmForZoteroVersionStatus -ProfileDir $ProfilePath -ManifestAdapter $Adapter
    } $profileRoot $manifestAdapter
    Assert-True $status.compliant "an active current official-channel install should be compliant"
    Assert-True ($status.installedVersion -eq "3.8.26") "installed version should be reported"
    Assert-True ($status.latestVersion -eq "3.8.26") "latest version should come from the injected manifest"

    $newerAdapter = {
        [pscustomobject]@{
            addons = [pscustomobject]@{
                "zotero-llm@github.com.yilewang" = [pscustomobject]@{
                    updates = @([pscustomobject]@{ version = "3.9.0" })
                }
            }
        }
    }
    $outdated = & $module {
        param($ProfilePath, $Adapter)
        Get-LlmForZoteroVersionStatus -ProfileDir $ProfilePath -ManifestAdapter $Adapter
    } $profileRoot $newerAdapter
    Assert-True (-not $outdated.compliant) "an outdated install should not be compliant"
    Write-Output "All $passed version-check assertions passed."
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
