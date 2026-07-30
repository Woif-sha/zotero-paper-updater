Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Find-ZoteroMcpPrefsFile {
    $profilesRoot = Join-Path $env:APPDATA "Zotero\Zotero\Profiles"
    if (-not (Test-Path -LiteralPath $profilesRoot -PathType Container)) {
        throw "Zotero profiles directory not found: $profilesRoot"
    }

    $preferenceFiles = @(
        Get-ChildItem -LiteralPath $profilesRoot -Directory |
            ForEach-Object { Join-Path $_.FullName "prefs.js" } |
            Where-Object {
                (Test-Path -LiteralPath $_ -PathType Leaf) -and
                (Select-String `
                    -LiteralPath $_ `
                    -Pattern "codexZoteroMcpBearerToken" `
                    -Quiet)
            } |
            Sort-Object { (Get-Item -LiteralPath $_).LastWriteTimeUtc } -Descending
    )
    if ($preferenceFiles.Count -eq 0) {
        throw "llm-for-zotero MCP bearer token was not found in any Zotero profile"
    }
    $preferenceFiles[0]
}

function Get-ZoteroMcpBearerToken {
    param([Parameter(Mandatory = $true)][string]$PrefsPath)

    $line = (
        Select-String -LiteralPath $PrefsPath -Pattern "codexZoteroMcpBearerToken" |
            Select-Object -Last 1
    ).Line
    if ($line -notmatch 'codexZoteroMcpBearerToken"\s*,\s*"([^"]+)"') {
        throw "Could not parse llm-for-zotero MCP bearer token"
    }
    $Matches[1]
}

function Invoke-LlmForZoteroMcp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ToolName,

        [Parameter(Mandatory = $true)]
        [object]$Arguments,

        [string]$Endpoint = "http://127.0.0.1:23119/llm-for-zotero/mcp",

        [scriptblock]$TransportAdapter
    )

    $endpointUri = [uri]$Endpoint
    if ($endpointUri.Scheme -ne "http" -or
        $endpointUri.Host -notin @("127.0.0.1", "localhost") -or
        $endpointUri.AbsolutePath -ne "/llm-for-zotero/mcp") {
        throw "Endpoint must be the llm-for-zotero MCP path on the local loopback interface"
    }

    $prefsPath = Find-ZoteroMcpPrefsFile
    $token = Get-ZoteroMcpBearerToken -PrefsPath $prefsPath
    $request = [ordered]@{
        jsonrpc = "2.0"
        id = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        method = "tools/call"
        params = [ordered]@{
            name = $ToolName
            arguments = $Arguments
        }
    }
    try {
        if ($null -ne $TransportAdapter) {
            $response = & $TransportAdapter $request $token $Endpoint
        }
        else {
            $tempPath = Join-Path ([IO.Path]::GetTempPath()) (
                "llm-for-zotero-mcp-" + [guid]::NewGuid().ToString("N") + ".json"
            )
            try {
                [IO.File]::WriteAllText(
                    $tempPath,
                    ($request | ConvertTo-Json -Depth 100 -Compress),
                    [Text.UTF8Encoding]::new($false)
                )
                $curlConfig = @"
silent
show-error
header = "Authorization: Bearer $token"
header = "Content-Type: application/json"
data-binary = "@$($tempPath.Replace('\', '/'))"
url = "$Endpoint"
"@
                $response = $curlConfig | & curl.exe --config -
                if ($LASTEXITCODE -ne 0) {
                    throw "llm-for-zotero MCP request failed with curl exit code $LASTEXITCODE"
                }
            }
            finally {
                if (Test-Path -LiteralPath $tempPath) {
                    Remove-Item -LiteralPath $tempPath -Force
                }
            }
        }
        try {
            $response | ConvertFrom-Json -Depth 100
        }
        catch {
            throw "llm-for-zotero MCP returned invalid JSON"
        }
    }
    finally {
        $token = $null
    }
}

Export-ModuleMember -Function Invoke-LlmForZoteroMcp
