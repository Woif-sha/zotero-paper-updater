[CmdletBinding(DefaultParameterSetName = "List")]
param(
    [Parameter(ParameterSetName = "Initialize")]
    [switch]$Initialize,

    [Parameter(ParameterSetName = "List")]
    [switch]$ListTools,

    [Parameter(Mandatory = $true, ParameterSetName = "Call")]
    [string]$ToolName,

    [Parameter(ParameterSetName = "Call")]
    [string]$ArgumentsJson = "{}",

    [string]$Endpoint = "http://127.0.0.1:23119/llm-for-zotero/mcp"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$endpointUri = [uri]$Endpoint
if (
    $endpointUri.Scheme -ne "http" -or
    $endpointUri.Host -notin @("127.0.0.1", "localhost") -or
    $endpointUri.AbsolutePath -ne "/llm-for-zotero/mcp"
) {
    throw "Endpoint must be the llm-for-zotero MCP path on the local loopback interface"
}

function Find-ZoteroPrefsFile {
    $profilesRoot = Join-Path $env:APPDATA "Zotero\Zotero\Profiles"
    if (-not (Test-Path -LiteralPath $profilesRoot -PathType Container)) {
        throw "Zotero profiles directory not found: $profilesRoot"
    }

    $matches = @(
        Get-ChildItem -LiteralPath $profilesRoot -Directory |
            ForEach-Object { Join-Path $_.FullName "prefs.js" } |
            Where-Object {
                (Test-Path -LiteralPath $_ -PathType Leaf) -and (Select-String -LiteralPath $_ -Pattern "codexZoteroMcpBearerToken" -Quiet)
            } |
            Sort-Object { (Get-Item -LiteralPath $_).LastWriteTime } -Descending
    )
    if ($matches.Count -eq 0) {
        throw "llm-for-zotero MCP bearer token was not found in any Zotero profile"
    }
    $matches[0]
}

function Get-ZoteroMcpBearerToken {
    param([Parameter(Mandatory = $true)][string]$PrefsPath)

    $line = (Select-String -LiteralPath $PrefsPath -Pattern "codexZoteroMcpBearerToken" | Select-Object -Last 1).Line
    if ($line -notmatch 'codexZoteroMcpBearerToken"\s*,\s*"([^"]+)"') {
        throw "Could not parse llm-for-zotero MCP bearer token"
    }
    $Matches[1]
}

$prefsPath = Find-ZoteroPrefsFile
$token = Get-ZoteroMcpBearerToken -PrefsPath $prefsPath
$requestId = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

if ($Initialize) {
    $request = [ordered]@{
        jsonrpc = "2.0"
        id = $requestId
        method = "initialize"
        params = [ordered]@{
            protocolVersion = "2025-06-18"
            capabilities = @{}
            clientInfo = [ordered]@{
                name = "zotero-paper-updater"
                version = "1.0"
            }
        }
    }
}
elseif ($PSCmdlet.ParameterSetName -eq "Call") {
    try {
        $arguments = $ArgumentsJson | ConvertFrom-Json -Depth 100
    }
    catch {
        throw "ArgumentsJson is not valid JSON: $($_.Exception.Message)"
    }
    $request = [ordered]@{
        jsonrpc = "2.0"
        id = $requestId
        method = "tools/call"
        params = [ordered]@{
            name = $ToolName
            arguments = $arguments
        }
    }
}
else {
    $request = [ordered]@{
        jsonrpc = "2.0"
        id = $requestId
        method = "tools/list"
        params = @{}
    }
}

$tempPath = Join-Path ([System.IO.Path]::GetTempPath()) ("llm-for-zotero-mcp-" + [guid]::NewGuid().ToString("N") + ".json")
try {
    [System.IO.File]::WriteAllText(
        $tempPath,
        ($request | ConvertTo-Json -Depth 100 -Compress),
        [System.Text.UTF8Encoding]::new($false)
    )
    $curlTempPath = $tempPath.Replace("\", "/")
    $curlConfig = @"
silent
show-error
header = "Authorization: Bearer $token"
header = "Content-Type: application/json"
data-binary = "@$curlTempPath"
url = "$Endpoint"
"@
    $response = $curlConfig | & curl.exe --config -
    if ($LASTEXITCODE -ne 0) {
        throw "llm-for-zotero MCP request failed with curl exit code $LASTEXITCODE"
    }
    try {
        $null = $response | ConvertFrom-Json -Depth 100
    }
    catch {
        throw "llm-for-zotero MCP returned invalid JSON: $response"
    }
    $response
}
finally {
    if (Test-Path -LiteralPath $tempPath) {
        Remove-Item -LiteralPath $tempPath -Force
    }
    $token = $null
}
